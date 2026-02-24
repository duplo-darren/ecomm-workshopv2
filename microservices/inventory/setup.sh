#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"

sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv postgresql postgresql-contrib libpq-dev

sudo systemctl enable --now postgresql

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='ecomm'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE USER ecomm WITH PASSWORD 'ecomm';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='ecomm_inventory'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE ecomm_inventory OWNER ecomm;"

python3 -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
pip install -r "$APP_DIR/requirements.txt"

echo ""
echo "Inventory setup complete. Run ./start.sh to launch."
