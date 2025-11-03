#!/usr/bin/env bash
set -euo pipefail

# Defaults
TLS_PORT="8443"
DOMAIN=""
EMAIL=""
WORKDIR="/opt/docker"
SITE_NAME="" # will default to $DOMAIN
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
LE_LIVE_BASE="/etc/letsencrypt/live"

# --------------- helpers ---------------
log() { echo -e ">>> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run as root."
  fi
}

check_bin() {
  command -v "$1" >/dev/null 2>&1
}

ensure_pkg() {
  local pkg="$1"
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Installing package: $pkg"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
}

parse_args() {
  while getopts ":d:e:p:" opt; do
    case "$opt" in
      d) DOMAIN="$OPTARG" ;;
      e) EMAIL="$OPTARG" ;;
      p) TLS_PORT="$OPTARG" ;;
      *) die "Unknown option. Usage: -d <domain> -e <email> [-p <tls_port>]" ;;
    esac
  done

  [[ -z "$DOMAIN" ]] && die "Domain is required. Use -d <domain>"
  [[ -z "$EMAIL" ]] && die "Email is required. Use -e <email>"
  SITE_NAME="${DOMAIN}"
}

# --------------- main steps ---------------
install_deps() {
  log "Checking dependencies..."
  ensure_pkg ca-certificates
  ensure_pkg curl
  ensure_pkg gnupg
  ensure_pkg lsb-release
  ensure_pkg software-properties-common

  # NGINX
  if ! check_bin nginx; then
    log "Installing nginx..."
    apt-get update -y
    apt-get install -y nginx
    systemctl enable nginx
  fi

  # Docker + compose v2
  if ! check_bin docker; then
    log "Installing Docker..."
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker
  fi

  if ! docker compose version >/dev/null 2>&1; then
    log "Installing docker compose v2..."
    apt-get update -y
    apt-get install -y docker-compose-plugin
  fi

  # Certbot
  if ! check_bin certbot; then
    log "Installing certbot..."
    apt-get update -y
    apt-get install -y certbot
  fi
}

obtain_cert() {
  # Stop nginx to free :80 for standalone challenge
  log "Obtaining/renewing certificate for ${DOMAIN} via certbot (standalone)..."
  systemctl stop nginx || true

  certbot certonly --standalone \
    --non-interactive --agree-tos \
    --email "${EMAIL}" \
    -d "${DOMAIN}" || {
      systemctl start nginx || true
      die "Certbot failed. Check DNS (A/AAAA must point to this server) and firewall for port 80."
    }

  systemctl start nginx
}

write_nginx_vhost() {
  log "Writing NGINX vhost for ${DOMAIN} (TLS on ${TLS_PORT})..."

  mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"
  local vhost_path="${NGINX_SITES_AVAILABLE}/${SITE_NAME}"

  cat > "${vhost_path}" <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host:${TLS_PORT}\$request_uri;
}

server {
    listen ${TLS_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${LE_LIVE_BASE}/${DOMAIN}/fullchain.pem;
    ssl_certificate_key ${LE_LIVE_BASE}/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Increase headers/body limits for client configs
    client_max_body_size 50m;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_redirect off;

        # 3x-ui web panel listens HTTP on 2053
        proxy_pass http://127.0.0.1:2053;
    }
}
NGINX

  ln -sf "${vhost_path}" "${NGINX_SITES_ENABLED}/${SITE_NAME}"

  nginx -t
  systemctl reload nginx
  log "NGINX vhost applied."
}

prepare_workdir() {
  mkdir -p "${WORKDIR}/db" "${WORKDIR}/cert"
}

write_compose() {
  log "Writing docker-compose.yml..."

  cat > "${WORKDIR}/docker-compose.yml" <<'YAML'
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    # Use host networking so x-ui listens directly on host ports (2053, 2096, etc.)
    network_mode: host
    hostname: __DOMAIN_PLACEHOLDER__
    tty: true
    restart: unless-stopped
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    volumes:
      - ${PWD}/db/:/etc/x-ui/
      - ${PWD}/cert/:/root/cert/
      - /etc/letsencrypt/:/etc/letsencrypt/:rw
YAML

  # Replace placeholder with the actual domain
  sed -i "s/__DOMAIN_PLACEHOLDER__/${DOMAIN}/g" "${WORKDIR}/docker-compose.yml"
}

launch_stack() {
  log "Launching 3x-ui container..."
  pushd "${WORKDIR}" >/dev/null
  docker compose pull
  docker compose up -d
  popd >/dev/null
}

final_status() {
  log "Setup complete!"
  echo "=========================================="
  echo "Domain: ${DOMAIN}"
  echo "NGINX listens on:"
  echo " - HTTP 80 -> redirect to HTTPS"
  echo " - HTTPS ${TLS_PORT} -> proxy to 3x-ui (HTTP 2053)"
  echo
  echo "3x-ui is running in 'network_mode: host' and its web panel listens on port 2053 (HTTP)."
  echo "TLS is terminated by NGINX on port ${TLS_PORT}."
  echo
  echo "Manage with: cd ${WORKDIR} && docker compose logs|restart|down|up -d"
  echo "Check access at: https://${DOMAIN}:${TLS_PORT}/"
  echo "=========================================="
}

# --------------- run ---------------
require_root
parse_args "$@"
install_deps
prepare_workdir

# If certificate not present, obtain it. If present, skip issuance and just use it.
if [[ ! -f "${LE_LIVE_BASE}/${DOMAIN}/fullchain.pem" ]]; then
  obtain_cert
else
  log "Existing certificate found at ${LE_LIVE_BASE}/${DOMAIN}. Skipping issuance."
fi

write_nginx_vhost
write_compose
launch_stack
final_status
