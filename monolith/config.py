import os

BASE_DIR = os.path.abspath(os.path.dirname(__file__))


class Config:
    SQLALCHEMY_DATABASE_URI = os.environ.get(
        "DATABASE_URL", "postgresql://ecomm:ecomm@localhost:5432/ecomm"
    )
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    UPLOAD_FOLDER = os.path.join(BASE_DIR, "static", "uploads")
    STORAGE_BACKEND = os.environ.get("STORAGE_BACKEND", "local")

    # Service URLs - when None, use direct local calls (monolith mode)
    # Set these to HTTP URLs to switch to microservice mode
    CATALOG_SERVICE_URL = os.environ.get("CATALOG_SERVICE_URL")
    INVENTORY_SERVICE_URL = os.environ.get("INVENTORY_SERVICE_URL")
