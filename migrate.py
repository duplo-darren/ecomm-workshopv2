"""Migrate data from the monolith ecomm database to the microservice databases.

Environment variables:
    MONOLITH_DATABASE_URL   - monolith connection string (default: local ecomm)
    CATALOG_DATABASE_URL    - catalog microservice DB (required unless secret is used)
    INVENTORY_DATABASE_URL  - inventory microservice DB (required unless secret is used)
    CATALOG_DB_SECRET       - AWS Secrets Manager secret name for catalog DB credentials
    CATALOG_DB_NAME         - Database name for catalog (used with CATALOG_DB_SECRET)
    INVENTORY_DB_SECRET     - AWS Secrets Manager secret name for inventory DB credentials
    INVENTORY_DB_NAME       - Database name for inventory (used with INVENTORY_DB_SECRET)
    TARGET_S3_BUCKET        - S3 bucket name for image upload (if not set, images are copied locally)

Usage:
    python migrate.py
"""

import json
import mimetypes
import os
import shutil
import sys

import psycopg2


def get_db_url_from_secret(secret_name, dbname):
    """Retrieve a database URL from AWS Secrets Manager.

    Expects the secret to contain JSON with keys:
        host, port, username, password
    The dbname is provided separately since the secret typically
    contains only connection credentials.
    """
    import boto3

    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    client = boto3.client("secretsmanager", region_name=region)
    resp = client.get_secret_value(SecretId=secret_name)
    secret = json.loads(resp["SecretString"])
    return (
        f"postgresql://{secret['username']}:{secret['password']}"
        f"@{secret['host']}:{secret.get('port', 5432)}/{dbname}"
    )


def resolve_db_url(env_var, secret_env_var, dbname_env_var, label):
    """Return a database URL from the env var, or fall back to Secrets Manager."""
    url = os.environ.get(env_var)
    if url:
        return url
    secret_name = os.environ.get(secret_env_var)
    if secret_name:
        # First try to get dbname from environment variable
        dbname = os.environ.get(dbname_env_var)
        if not dbname:
            # Fall back to interactive prompt
            dbname = input(f"Database name for {label}: ").strip()
        if not dbname:
            print(f"No database name provided for {label}, aborting.")
            sys.exit(1)
        print(f"Fetching {env_var} from Secrets Manager ({secret_name})...")
        return get_db_url_from_secret(secret_name, dbname)
    return None


MONOLITH_URL = os.environ.get(
    "MONOLITH_DATABASE_URL", "postgresql://ecomm:ecomm@localhost:5432/ecomm"
)
CATALOG_URL = resolve_db_url("CATALOG_DATABASE_URL", "CATALOG_DB_SECRET", "CATALOG_DB_NAME", "catalog")
INVENTORY_URL = resolve_db_url("INVENTORY_DATABASE_URL", "INVENTORY_DB_SECRET", "INVENTORY_DB_NAME", "inventory")

if not CATALOG_URL or not INVENTORY_URL:
    print("Error: catalog and inventory database URLs must be provided.")
    print("Set either the URL directly or a Secrets Manager secret name:")
    print("  export CATALOG_DATABASE_URL=postgresql://user:pass@host:5432/ecomm_catalog")
    print("  export INVENTORY_DATABASE_URL=postgresql://user:pass@host:5432/ecomm_inventory")
    print("or:")
    print("  export CATALOG_DB_SECRET=my/catalog/db/secret")
    print("  export CATALOG_DB_NAME=dbcatalog01")
    print("  export INVENTORY_DB_SECRET=my/inventory/db/secret")
    print("  export INVENTORY_DB_NAME=dbinventory01")
    sys.exit(1)

UPLOADS_SRC = os.path.join(os.path.dirname(__file__), "monolith", "static", "uploads")
UPLOADS_DST = os.path.join(
    os.path.dirname(__file__), "microservices", "catalog", "static", "uploads"
)


def create_tables(catalog_conn, inventory_conn):
    """Create target tables if they don't exist."""
    with catalog_conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS products (
                id SERIAL PRIMARY KEY,
                name VARCHAR(200) NOT NULL,
                description TEXT DEFAULT '',
                price DOUBLE PRECISION NOT NULL,
                image_path VARCHAR(500) DEFAULT '',
                created_at TIMESTAMP DEFAULT (NOW() AT TIME ZONE 'utc')
            )
        """)
    catalog_conn.commit()

    with inventory_conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS inventory (
                id SERIAL PRIMARY KEY,
                product_id INTEGER NOT NULL,
                quantity INTEGER NOT NULL DEFAULT 0,
                warehouse VARCHAR(100) DEFAULT 'main',
                updated_at TIMESTAMP DEFAULT (NOW() AT TIME ZONE 'utc')
            )
        """)
        cur.execute("""
            CREATE INDEX IF NOT EXISTS ix_inventory_product_id ON inventory (product_id)
        """)
    inventory_conn.commit()
    print("Target tables verified.")


def migrate_products(mono_conn, catalog_conn):
    with mono_conn.cursor() as src:
        src.execute(
            "SELECT id, name, description, price, image_path, created_at FROM products"
        )
        rows = src.fetchall()

    if not rows:
        print("No products to migrate.")
        return

    with catalog_conn.cursor() as dst:
        for row in rows:
            dst.execute(
                "INSERT INTO products (id, name, description, price, image_path, created_at) "
                "VALUES (%s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (id) DO NOTHING",
                row,
            )
        dst.execute("SELECT setval('products_id_seq', (SELECT COALESCE(MAX(id), 0) + 1 FROM products), false)")
    catalog_conn.commit()
    print(f"Migrated {len(rows)} products.")


def migrate_inventory(mono_conn, inventory_conn):
    with mono_conn.cursor() as src:
        src.execute(
            "SELECT id, product_id, quantity, warehouse, updated_at FROM inventory"
        )
        rows = src.fetchall()

    if not rows:
        print("No inventory to migrate.")
        return

    with inventory_conn.cursor() as dst:
        for row in rows:
            dst.execute(
                "INSERT INTO inventory (id, product_id, quantity, warehouse, updated_at) "
                "VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (id) DO NOTHING",
                row,
            )
        dst.execute("SELECT setval('inventory_id_seq', (SELECT COALESCE(MAX(id), 0) + 1 FROM inventory), false)")
    inventory_conn.commit()
    print(f"Migrated {len(rows)} inventory records.")


def migrate_images_s3(bucket_name):
    import boto3

    s3 = boto3.client("s3")
    files = [f for f in os.listdir(UPLOADS_SRC) if os.path.isfile(os.path.join(UPLOADS_SRC, f))]
    if not files:
        print("No images to upload.")
        return
    for filename in sorted(files):
        filepath = os.path.join(UPLOADS_SRC, filename)
        key = f"uploads/{filename}"
        content_type = mimetypes.guess_type(filepath)[0] or "application/octet-stream"
        s3.upload_file(filepath, bucket_name, key, ExtraArgs={"ContentType": content_type})
        print(f"  Uploaded {filename} -> s3://{bucket_name}/{key}")
    print(f"Uploaded {len(files)} images to S3.")


def migrate_images_local():
    os.makedirs(UPLOADS_DST, exist_ok=True)
    files = [f for f in os.listdir(UPLOADS_SRC) if os.path.isfile(os.path.join(UPLOADS_SRC, f))]
    if not files:
        print("No images to copy.")
        return
    for filename in sorted(files):
        shutil.copy2(os.path.join(UPLOADS_SRC, filename), os.path.join(UPLOADS_DST, filename))
        print(f"  Copied {filename}")
    print(f"Copied {len(files)} images to {UPLOADS_DST}")


def main():
    mono_conn = psycopg2.connect(MONOLITH_URL)
    catalog_conn = psycopg2.connect(CATALOG_URL)
    inventory_conn = psycopg2.connect(INVENTORY_URL)

    try:
        print("Creating target tables if needed...")
        create_tables(catalog_conn, inventory_conn)

        print("Migrating products...")
        migrate_products(mono_conn, catalog_conn)

        print("Migrating inventory...")
        migrate_inventory(mono_conn, inventory_conn)

        print("\nMigrating images...")
        bucket_name = os.environ.get("TARGET_S3_BUCKET")
        if bucket_name:
            migrate_images_s3(bucket_name)
        else:
            print("TARGET_S3_BUCKET not set, copying images locally.")
            migrate_images_local()

        print("\nMigration complete.")
    finally:
        mono_conn.close()
        catalog_conn.close()
        inventory_conn.close()


if __name__ == "__main__":
    main()
