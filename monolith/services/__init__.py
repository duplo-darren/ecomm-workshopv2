import requests
from flask import current_app


class ServiceClient:
    """Abstraction for inter-service communication.

    In monolith mode (service URL is None), calls the service layer directly.
    In microservice mode (service URL is set), makes HTTP requests.
    This is the key pattern participants will explore in the workshop.
    """

    @staticmethod
    def get(service, path, **kwargs):
        url = _get_service_url(service)
        if url is None:
            return _local_call("GET", service, path, **kwargs)
        resp = requests.get(f"{url}/api{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()

    @staticmethod
    def put(service, path, **kwargs):
        url = _get_service_url(service)
        if url is None:
            return _local_call("PUT", service, path, **kwargs)
        resp = requests.put(f"{url}/api{path}", **kwargs)
        resp.raise_for_status()
        return resp.json()


def _get_service_url(service):
    if service == "catalog":
        return current_app.config.get("CATALOG_SERVICE_URL")
    elif service == "inventory":
        return current_app.config.get("INVENTORY_SERVICE_URL")
    return None


def _local_call(method, service, path, **kwargs):
    """Make an internal call using Flask's test client."""
    with current_app.test_client() as client:
        prefix = "/api"
        full_path = f"{prefix}{path}"
        if method == "GET":
            resp = client.get(full_path)
        elif method == "PUT":
            resp = client.put(full_path, json=kwargs.get("json"))
        else:
            resp = client.get(full_path)
        return resp.get_json()
