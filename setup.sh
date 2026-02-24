#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ensure HOME is set (cloud-init may not set it)
export HOME="${HOME:-$(getent passwd "$(whoami)" | cut -d: -f6)}"

# Install system dependencies
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv postgresql postgresql-contrib libpq-dev nginx \
  ca-certificates curl unzip socat

# Set up SSL certificate with acme.sh
echo "Setting up SSL certificate..."

# Get public IP address
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || curl -s https://api.ipify.org)
echo "Public IP: $PUBLIC_IP"

# Create webroot directory and set ownership
sudo mkdir -p /var/www/html
sudo chown -R "$(whoami):$(whoami)" /var/www/html

# Install acme.sh
if [ ! -d "$HOME/.acme.sh" ]; then
  curl https://get.acme.sh | sh
  source "$HOME/.acme.sh/acme.sh.env"
fi

# Request certificate using the public IP
"$HOME/.acme.sh/acme.sh" --issue --server letsencrypt --cert-profile shortlived --days 3 -d "$PUBLIC_IP" --webroot /var/www/html/

# Install AWSCLI

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Install Docker
if ! command -v docker &> /dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin jq
fi

# Allow current user to run docker without sudo
sudo groupadd -f docker
sudo usermod -aG docker "$(whoami)"

# Install code-server
if ! command -v code-server &> /dev/null; then
  curl -fsSL https://code-server.dev/install.sh | sh
fi

# Generate a random password for code-server
CODE_SERVER_PASSWORD=$(head -c 100 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 10)

# Configure code-server
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml <<CODESERVER_CONFIG
bind-addr: 127.0.0.1:8080
auth: password
password: ${CODE_SERVER_PASSWORD}
cert: false
CODESERVER_CONFIG

# Display code-server password on login (use target user's home, not root's)
USER_HOME="$(getent passwd "$(whoami)" | cut -d: -f6)"
cat >> "${USER_HOME}/.bashrc" <<BASHRC

# --- Workshop: code-server password ---
echo ""
echo "============================================"
echo "  code-server password: ${CODE_SERVER_PASSWORD}"
echo "============================================"
echo ""
BASHRC

# Create systemd service for code-server
sudo tee /etc/systemd/system/code-server.service > /dev/null <<CODESERVER_SERVICE
[Unit]
Description=code-server
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/code-server --bind-addr 127.0.0.1:8080
Restart=on-failure

[Install]
WantedBy=multi-user.target
CODESERVER_SERVICE

# Enable and start code-server
sudo systemctl daemon-reload
sudo systemctl enable --now code-server

# Start and enable PostgreSQL
sudo systemctl enable --now postgresql

# Create database and user
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='ecomm'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE USER ecomm WITH PASSWORD 'ecomm';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='ecomm'" | grep -q 1 \
  || sudo -u postgres psql -c "CREATE DATABASE ecomm OWNER ecomm;"

# Set up Python virtual environment and install dependencies
python3 -m venv "$APP_DIR/venv"
source "$APP_DIR/venv/bin/activate"
pip install -r "$APP_DIR/monolith/requirements.txt"

# Configure nginx as reverse proxy with SSL
# Get the certificate path using the public IP
CERT_DIR="$HOME/.acme.sh/${PUBLIC_IP}_ecc"

sudo tee /etc/nginx/sites-available/ecomm > /dev/null <<NGINX
server {
    listen 80;
    server_name _;

    # Webroot for acme.sh certificate validation
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate ${CERT_DIR}/fullchain.cer;
    ssl_certificate_key ${CERT_DIR}/${PUBLIC_IP}.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /code/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_set_header Accept-Encoding gzip;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/ecomm /etc/nginx/sites-enabled/ecomm
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
sudo snap install kubectl --classic

echo ""
echo "Setup complete. Run ./start.sh to launch the app."
echo "code-server is available at http://your-server/code"
echo "code-server password: $CODE_SERVER_PASSWORD"
echo "export AWS_REGION=\$(bash ~/ecomm-workshop/get_aws_region.sh)" >> ~/.bashrc
echo "export AWS_BEARER_TOKEN=\$(python3 ~/ecomm-workshop/bedrock.py)" >> ~/.bashrc
./setup_opencode.sh
