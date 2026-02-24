from flask import Flask, jsonify
from .config import Config
from .routes import frontend_bp


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    app.register_blueprint(frontend_bp)

    @app.route("/health")
    def health():
        return jsonify({"status": "healthy"})

    return app
