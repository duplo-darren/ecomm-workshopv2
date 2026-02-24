import os


class Config:
    CATALOG_SERVICE_URL = os.environ.get(
        "CATALOG_SERVICE_URL", "http://localhost:8001"
    )
    INVENTORY_SERVICE_URL = os.environ.get(
        "INVENTORY_SERVICE_URL", "http://localhost:8002"
    )
