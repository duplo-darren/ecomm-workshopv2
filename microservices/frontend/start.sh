#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PARENT_DIR="$(dirname "$APP_DIR")"

source "$APP_DIR/venv/bin/activate"

echo "Starting frontend service on port 8000 (nginx proxies from port 80)..."
cd "$PARENT_DIR"
gunicorn --bind 127.0.0.1:8000 --workers 2 --access-logfile - "frontend.app:create_app()"
