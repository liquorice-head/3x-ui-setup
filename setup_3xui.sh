#!/usr/bin/env bash

# A script to deploy 3x-ui in Docker with local NGINX and Certbot.
# Usage:
#   ./setup_3xui.sh <your-domain> [8443]

set -e

### 0. Check input
DOMAIN="$1"
HTTPS_PORT="$2"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain> [<https-port>]"
  exit 1
fi

if [ -z "$HTTPS_PORT" ]; then
  HTTPS_PORT=8443
fi

echo "Domain to configure: $DOMAIN"
echo "HTTPS port: $HTTPS_PORT"

### 1. Install required packages

echo ">>> Installing Docker, Docker Compose Plugin, NGINX, Certbot..."

# Add Docker repository if not already present
if ! command -v docker >/dev/null; then
  sudo apt update -y
  sudo apt install -y ca-certificates curl gnupg lsb-release

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update -y
fi

sudo apt install -y docker.io docker-compose-plugin nginx certbot python3-certbot-nginx

# Enable services
sudo systemctl enable --now docker
sudo systemctl enable --now nginx

### 2. Create temporary NGINX config (port 80 for ACME)

echo ">>> Creating temporary NGINX config for Let’s Encrypt..."

NGINX_CONF_PATH="/etc/nginx/sites-available/$DOMAIN"

sudo bash -c "cat > $NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }

    location / {
        return 200 "Temporary config for ACME challenge on $DOMAIN";
    }
}
EOF

sudo mkdir -p /var/www/$DOMAIN
sudo chown -R www-data:www-data /var/www/$DOMAIN
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN 2>/dev/null || true

echo ">>> Restarting NGINX..."
sudo nginx -t && sudo systemctl restart nginx

### 3. Obtain Let's Encrypt cert

echo ">>> Running certbot to obtain the certificate..."
sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --no-eff-email --email "admin@$DOMAIN" || {
  echo "ERROR: certbot could not obtain the certificate."
  exit 1
}

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
  echo "ERROR: certificate or key not found."
  exit 1
fi

### 4. Create final NGINX config with HTTPS

echo ">>> Creating final NGINX config..."

sudo bash -c "cat > $NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host:$HTTPS_PORT\$request_uri;
}

server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://localhost:443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo ">>> Restarting NGINX..."
sudo nginx -t && sudo systemctl restart nginx

### 5. Create docker-compose.yml for 3x-ui

echo ">>> Creating docker-compose.yml..."
cat > docker-compose.yml <<EOF
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    hostname: $DOMAIN
    volumes:
      - \${PWD}/db/:/etc/x-ui/
      - \${PWD}/cert/:/root/cert/
      - /etc/letsencrypt/:/etc/letsencrypt/:rw
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    tty: true
    network_mode: host
    restart: unless-stopped
EOF

### 6. Launch 3x-ui

echo ">>> Launching 3x-ui container..."
sudo docker compose up -d

### 7. Done

echo
echo "=========================================="
echo "Setup complete!"
echo "Domain: $DOMAIN"
echo "NGINX listens on:"
echo " - HTTP 80 → redirect to HTTPS"
echo " - HTTPS $HTTPS_PORT → proxy to 3x-ui (port 443)"
echo
echo "3x-ui is running in 'network_mode: host' and listening on port 443"
echo "You can manage it via: docker compose logs, docker compose restart, etc."
echo "Check access at: https://$DOMAIN:$HTTPS_PORT/"
echo "=========================================="
