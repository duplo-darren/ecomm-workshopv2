#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$APP_DIR")"

source "$APP_DIR/venv/bin/activate"

cd "$PARENT_DIR"
python -c "
from catalog.app import create_app
from catalog.models import db
app = create_app()
with app.app_context():
    db.drop_all()
    db.create_all()
    print('Database reset.')
"
python -m catalog.seed

echo "Starting catalog service on port 8001..."
gunicorn --bind 127.0.0.1:8001 --workers 2 --access-logfile - "catalog.app:create_app()"
