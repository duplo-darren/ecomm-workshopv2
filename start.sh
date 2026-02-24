#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$APP_DIR/venv/bin/activate"
#python "$APP_DIR/reset_db.py"
python "$APP_DIR/monolith/seed.py"

echo "Starting gunicorn on port 8000 (nginx proxies from port 80)..."
cd "$APP_DIR/monolith"
gunicorn --bind 127.0.0.1:8000 --workers 2 --access-logfile - "app:create_app()"
