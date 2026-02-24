import requests
from flask import current_app


class ServiceClient:
    """HTTP-only client for inter-service communication."""

    @staticmethod
    def get(service, path, **kwargs):
        url = _get_service_url(service)
        resp = requests.get(f"{url}{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def post(service, path, **kwargs):
        url = _get_service_url(service)
        resp = requests.post(f"{url}{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def put(service, path, **kwargs):
        url = _get_service_url(service)
        resp = requests.put(f"{url}{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()


def _get_service_url(service):
    if service == "catalog":
        return current_app.config["CATALOG_SERVICE_URL"]
    elif service == "inventory":
        return current_app.config["INVENTORY_SERVICE_URL"]
    raise ValueError(f"Unknown service: {service}")
