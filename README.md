# **setup_3xui.sh** Script

This script is designed for **quick deployment** of [3x-ui](https://github.com/mhsanaei/3x-ui) in Docker along with a local NGINX and a Let’s Encrypt certificate on an Ubuntu/Debian server.

## What the Script Does
1. Installs Docker, Docker Compose, NGINX, and Certbot (Let’s Encrypt).
2. Sets up a minimal NGINX configuration for domain verification via Let’s Encrypt.
3. Obtains/renews the Let’s Encrypt certificate for the specified domain.
4. Creates the final NGINX config that listens on HTTP (80), redirects to HTTPS (default port 8443), and proxies traffic to 3x-ui (port 443 via `network_mode: host`).
5. Generates a `docker-compose.yml` with the specified volumes, `tty: true`, and **launches** the 3x-ui container.
6. Finally, enables Docker to start on boot again.

## Requirements
- Ubuntu/Debian or a similar system with the `apt` package manager.
- Open ports 80 (HTTP) and your chosen HTTPS port (8443 by default).
- A properly set up DNS A record for your domain, pointing to your server’s IP.

## Installation and Usage
1. Copy the script into a file named `setup_3xui.sh`.
2. Make it executable:
   ```bash
   chmod +x setup_3xui.sh
   ```
3. Run it, providing your domain and (optionally) the HTTPS port:
   ```bash
   ./setup_3xui.sh <your-domain> [https-port]
   ```
   If you don’t specify a port, 8443 will be used by default.

## Results
-	A temporary NGINX config for Let’s Encrypt validation will be created in /etc/nginx/sites-available/<domain>, followed by the final proxy config.
-	The certificate and key will be located at /etc/letsencrypt/live/<domain>.
-	A docker-compose.yml file will appear in the current directory, configured for 3x-ui with the required volumes and network_mode: host.
-	The script will automatically start the 3x-ui container and enable Docker to start on boot.

Important Points
-	If you want to use the standard HTTPS port 443 in NGINX, adjust the script and/or move 3x-ui to a different port to avoid conflicts.
-	Make sure your firewall (UFW, iptables) does not block the required ports.
-	Certbot automatically creates cron jobs for certificate renewal. Check that they are functioning as intended.
