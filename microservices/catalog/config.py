import os
import json

BASE_DIR = os.path.abspath(os.path.dirname(__file__))


def get_database_url():
    """Fetch DB credentials from AWS Secrets Manager, fall back to DATABASE_URL env var.

    Environment variables:
        DATABASE_URL    - full connection string (takes priority)
        DB_SECRET_NAME  - Secrets Manager secret name
        DB_NAME         - database name (required when using secret)
        AWS_REGION / AWS_DEFAULT_REGION - region (default: us-east-1)
    """
    url = os.environ.get("DATABASE_URL")
    if url:
        return url

    secret_name = os.environ.get("DB_SECRET_NAME")
    db_name = os.environ.get("DB_NAME")
    if not secret_name or not db_name:
        return "postgresql://ecomm:ecomm@localhost:5432/ecomm_catalog"

    import boto3

    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))
    client = boto3.client("secretsmanager", region_name=region)
    resp = client.get_secret_value(SecretId=secret_name)
    secret = json.loads(resp["SecretString"])
    return (
        f"postgresql://{secret['username']}:{secret['password']}"
        f"@{secret['host']}:{secret.get('port', 5432)}/{db_name}"
    )


class Config:
    SQLALCHEMY_DATABASE_URI = get_database_url()
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    UPLOAD_FOLDER = os.path.join(BASE_DIR, "static", "uploads")
