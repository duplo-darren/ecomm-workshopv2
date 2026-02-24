from flask import Flask, jsonify
from .config import Config
from .models import db
from .routes import inventory_bp


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    db.init_app(app)

    app.register_blueprint(inventory_bp, url_prefix="/api")

    @app.route("/health")
    def health():
        db.session.execute(db.text("SELECT 1"))
        return jsonify({"status": "healthy"})

    with app.app_context():
        db.create_all()

    return app
