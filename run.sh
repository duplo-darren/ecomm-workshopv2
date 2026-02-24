#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- helpers ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

# ---------- 1. Wait for apt lock ----------
echo "Waiting for apt lock to be free..."
APT_TIMEOUT=300
elapsed=0
while fuser /var/lib/dpkg/lock-frontend &>/dev/null || fuser /var/lib/apt/lists/lock &>/dev/null; do
    if (( elapsed >= APT_TIMEOUT )); then
        echo -e "${RED}ERROR: apt lock still held after ${APT_TIMEOUT}s. Aborting.${NC}"
        echo "Check what is holding the lock:"
        echo "  sudo lsof /var/lib/dpkg/lock-frontend"
        exit 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    echo "  ...still waiting (${elapsed}s)"
done
pass "apt lock is free"

# ---------- 2. Run setup.sh ----------
echo ""
echo "Running setup.sh..."
SETUP_LOG=$(mktemp)
if bash "$APP_DIR/setup.sh" 2>&1 | tee "$SETUP_LOG"; then
    pass "setup.sh completed successfully"
else
    echo -e "${RED}setup.sh failed. Last 30 lines of output:${NC}"
    tail -30 "$SETUP_LOG"
    rm -f "$SETUP_LOG"
    exit 1
fi
rm -f "$SETUP_LOG"

# ---------- 3. Post-setup health checks ----------
echo ""
echo "Running post-setup checks..."
CHECKS_FAILED=0

check() {
    local label="$1"
    shift
    if "$@" &>/dev/null; then
        pass "$label"
    else
        fail "$label"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

check "python3 installed"            command -v python3
check "venv directory exists"        test -d "$APP_DIR/venv"
check "flask importable in venv"     "$APP_DIR/venv/bin/python" -c "import flask"
check "PostgreSQL running"           systemctl is-active --quiet postgresql
check "Docker installed"             command -v docker
check "nginx running"                systemctl is-active --quiet nginx
check "nginx config valid"           sudo nginx -t
check "code-server running"          systemctl is-active --quiet code-server

if (( CHECKS_FAILED > 0 )); then
    echo ""
    echo -e "${RED}${CHECKS_FAILED} check(s) failed. Fix the issues above before starting the app.${NC}"
    exit 1
fi

echo ""
pass "All checks passed"

# ---------- 4. Start the app and verify ----------
echo ""
echo "Starting app (start.sh)..."
bash "$APP_DIR/start.sh" &
APP_PID=$!

HEALTHY=false
for i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:8000/ -o /dev/null; then
        HEALTHY=true
        break
    fi
    sleep 1
done

if $HEALTHY; then
    pass "gunicorn responding on port 8000 (PID: $APP_PID)"
else
    if kill -0 "$APP_PID" 2>/dev/null; then
        fail "gunicorn (PID: $APP_PID) is alive but not responding after 15s"
    else
        fail "gunicorn process has exited"
        wait "$APP_PID" 2>/dev/null || true
    fi
    exit 1
fi

check "nginx proxying port 80 to app" curl -sf http://127.0.0.1/ -o /dev/null

echo ""
pass "All systems go"
echo "  App URL:      http://<your-server-ip>"
echo "  Code-server:  http://<your-server-ip>/code"

# ---------- 5. Install checkin timer ----------
echo ""
echo "Installing checkin systemd timer..."

sudo tee /etc/systemd/system/ecomm-checkin.service >/dev/null <<UNIT
[Unit]
Description=Ecomm workshop check-in
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/checkin.py
WorkingDirectory=$APP_DIR
User=ubuntu
UNIT

sudo tee /etc/systemd/system/ecomm-checkin.timer >/dev/null <<UNIT
[Unit]
Description=Run ecomm check-in every 1 minute

[Timer]
OnBootSec=10s
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now ecomm-checkin.timer

if systemctl is-active --quiet ecomm-checkin.timer; then
    pass "ecomm-checkin.timer active"
else
    fail "ecomm-checkin.timer failed to start"
    exit 1
fi
