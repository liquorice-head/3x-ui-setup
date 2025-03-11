#!/usr/bin/env bash
#
# A quick script to deploy 3x-ui in Docker with local NGINX and Certbot.
# Example usage:
#   ./setup_3xui.sh liquorice-head.xyz [8443]
# By default, HTTPS will listen on 8443 if the second argument is not provided.

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

echo ">>> Installing Docker, Docker Compose, NGINX, Certbot..."
sudo apt update -y
sudo apt install -y docker.io docker-compose nginx certbot python3-certbot-nginx

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl enable nginx
sudo systemctl start nginx

### 2. Create a minimal NGINX config on port 80 (for obtaining the certificate)

echo ">>> Creating a minimal NGINX config for Let’s Encrypt..."

NGINX_CONF_PATH="/etc/nginx/sites-available/$DOMAIN"

sudo bash -c "cat > $NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Directory for Let’s Encrypt validation (acme-challenge)
    location /.well-known/acme-challenge/ {
        root /var/www/$DOMAIN;
    }

    # For all other paths, return a simple response (not to interfere with validation).
    location / {
        return 200 "Temporary config for ACME challenge on $DOMAIN";
    }
}
EOF

sudo mkdir -p /var/www/$DOMAIN
sudo chown -R www-data:www-data /var/www/$DOMAIN

# Enable the site
sudo ln -s /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN 2>/dev/null || true

echo ">>> Restarting NGINX..."
sudo nginx -t && sudo systemctl restart nginx

### 3. Obtain Let’s Encrypt certificate

echo ">>> Running certbot to obtain the certificate..."
sudo certbot certonly --nginx -d "$DOMAIN" --agree-tos --no-eff-email --email "admin@$DOMAIN" || {
  echo "ERROR: certbot could not obtain the certificate. Check logs and DNS correctness!"
  exit 1
}

SSL_CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
SSL_KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

# Check if certificate files exist
if [ ! -f "$SSL_CERT" ] || [ ! -f "$SSL_KEY" ]; then
  echo "ERROR: certificate or key not found: $SSL_CERT / $SSL_KEY"
  exit 1
fi

### 4. Create the final NGINX config

echo ">>> Creating the final NGINX config with HTTPS proxy..."
sudo bash -c "cat > $NGINX_CONF_PATH" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    # Redirect HTTP to HTTPS (explicitly include :$HTTPS_PORT for custom port)
    return 301 https://\$host:$HTTPS_PORT\$request_uri;
}

server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN;

    ssl_certificate     $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Forward all traffic to localhost:443 (where 3x-ui will be listening in Docker)
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

echo ">>> Launching the 3x-ui container..."
sudo docker-compose up -d

echo
echo "=========================================="
echo "Setup complete!"
echo "Domain: $DOMAIN"
echo "NGINX listens on:"
echo " - HTTP on 80 (redirect to HTTPS)"
echo " - HTTPS on port $HTTPS_PORT (proxy to 3x-ui:443)"
echo
echo "3x-ui is running in 'network_mode: host' and listening on port 443 on the host."
echo "You can manage it with docker-compose commands: docker-compose logs, docker-compose restart, etc."
echo
echo "Check access at:  http://$DOMAIN  -> redirect https://$DOMAIN:$HTTPS_PORT"
echo "=========================================="