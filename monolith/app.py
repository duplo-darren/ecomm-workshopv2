from flask import Flask
from config import Config
from services.catalog.models import db


def create_app():
    app = Flask(__name__, static_folder="static")
    app.config.from_object(Config)

    db.init_app(app)

    from services.frontend import frontend_bp
    from services.catalog import catalog_bp
    from services.inventory import inventory_bp

    app.register_blueprint(frontend_bp)
    app.register_blueprint(catalog_bp, url_prefix="/api")
    app.register_blueprint(inventory_bp, url_prefix="/api")

    with app.app_context():
        db.create_all()

    return app


if __name__ == "__main__":
    app = create_app()
    app.run(debug=True, host="0.0.0.0", port=5000)
