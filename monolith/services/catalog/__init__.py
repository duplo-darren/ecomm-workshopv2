from flask import Blueprint

catalog_bp = Blueprint("catalog", __name__)

from . import routes  # noqa: E402, F401
