from flask import Blueprint
import os

template_dir = os.path.join(os.path.dirname(__file__), "templates")
frontend_bp = Blueprint("frontend", __name__, template_folder=template_dir)

from . import routes  # noqa: E402, F401
