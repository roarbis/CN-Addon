#!/usr/bin/env bash
# ============================================================
#  Connect Nest Add-on — Startup Script
#  Reads HA Supervisor options, configures nginx, starts it
# ============================================================

set -euo pipefail

# ─── Colours ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[Connect Nest]${NC} $*"; }
success() { echo -e "${GREEN}[Connect Nest] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[Connect Nest] ⚠${NC} $*"; }
error()   { echo -e "${RED}[Connect Nest] ✗${NC} $*"; exit 1; }

# ─── Read add-on options from Supervisor ───────────────────
# HA Supervisor writes options to /data/options.json
HA_PORT=$(jq --raw-output '.ha_port // 8123' /data/options.json)
SSL=$(jq --raw-output '.ssl // false' /data/options.json)
CERTFILE=$(jq --raw-output '.certfile // "fullchain.pem"' /data/options.json)
KEYFILE=$(jq --raw-output '.keyfile // "privkey.pem"' /data/options.json)

info "============================================"
info "  Connect Nest v2025.1.0"
info "  Your smart home, beautifully connected."
info "============================================"
info "HA backend port: ${HA_PORT}"
info "SSL enabled: ${SSL}"

# ─── Version check via Supervisor API ──────────────────────
# Check HA version for compatibility logging
HA_VERSION=$(curl -s \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    http://supervisor/core/info 2>/dev/null \
    | jq -r '.data.version // "unknown"') || HA_VERSION="unknown"

info "HA Core version detected: ${HA_VERSION}"

# Warn if HA version is very old (pre-2024)
if [[ "$HA_VERSION" != "unknown" ]]; then
    YEAR=$(echo "$HA_VERSION" | cut -d. -f1)
    if [[ "$YEAR" -lt 2024 ]]; then
        warn "HA version ${HA_VERSION} is older than 2024."
        warn "Connect Nest is tested on 2024.1.0+."
        warn "Some branding strings may not be fully replaced."
        warn "Consider updating HA for best experience."
    fi
fi

# ─── Generate nginx config dynamically ─────────────────────
info "Configuring nginx..."

# Determine if running under HA ingress or direct port
INGRESS_PORT=8099

cat > /etc/nginx/nginx.conf << NGINX_EOF
worker_processes 1;
error_log /proc/1/fd/1 warn;
pid /run/nginx/nginx.pid;

load_module /usr/lib/nginx/modules/ngx_http_substitutions_filter_module.so;

events {
    worker_connections 512;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr [\$time_local] "\$request" \$status \$body_bytes_sent';
    access_log /proc/1/fd/1 main;

    sendfile on;
    keepalive_timeout 65;

    gzip on;
    gzip_types text/plain text/css application/json
               application/javascript text/javascript;

    # ─── Upstream: Home Assistant Core ───────────────────
    upstream ha_backend {
        server 127.0.0.1:${HA_PORT};
        keepalive 16;
    }

    # ─── Ingress server (for HA sidebar panel) ────────────
    server {
        listen ${INGRESS_PORT};
        server_name _;

        # CN branded manifest
        location = /manifest.json {
            alias /usr/share/nginx/cn-override/manifest.json;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Content-Type "application/manifest+json";
        }

        # CN icons
        location /static/icons/ {
            # Serve CN icons first, fall back to HA icons
            root /usr/share/nginx/cn-override;
            try_files \$uri @ha_backend;
            expires 30d;
        }

        # WebSocket support (essential for HA real-time updates)
        location /api/websocket {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            # Ingress headers required by HA Supervisor
            proxy_set_header X-Ingress-Path \$http_x_ingress_path;
            proxy_read_timeout 86400;
            proxy_send_timeout 86400;
        }

        # Named location for fallback
        location @ha_backend {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Ingress-Path \$http_x_ingress_path;
        }

        # All traffic → HA Core with runtime branding replacement
        location / {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            # Required for HA ingress
            proxy_set_header X-Ingress-Path \$http_x_ingress_path;

            # ── Runtime branding replacement ──────────────
            # Replaces ALL occurrences in proxied HTML/JS responses
            # This is the safety net that catches everything
            subs_filter 'Home Assistant' 'Connect Nest' gi;
            subs_filter 'home-assistant' 'connect-nest' gi;
            subs_filter_types text/html text/javascript
                              application/javascript application/json;

            proxy_buffer_size 128k;
            proxy_buffers 8 128k;
        }

        # Custom loading/error page
        error_page 502 503 504 /cn-error.html;
        location = /cn-error.html {
            root /usr/share/nginx/cn-override;
            internal;
        }
    }

    # ─── Direct access server (port 7080) ─────────────────
    server {
        listen 7080;
        server_name _;

        location = /manifest.json {
            alias /usr/share/nginx/cn-override/manifest.json;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
            add_header Content-Type "application/manifest+json";
        }

        location /static/icons/ {
            root /usr/share/nginx/cn-override;
            try_files \$uri @ha_direct;
            expires 30d;
        }

        location /api/websocket {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_read_timeout 86400;
            proxy_send_timeout 86400;
        }

        location @ha_direct {
            proxy_pass http://ha_backend;
        }

        location / {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;

            subs_filter 'Home Assistant' 'Connect Nest' gi;
            subs_filter 'home-assistant' 'connect-nest' gi;
            subs_filter_types text/html text/javascript
                              application/javascript application/json;

            proxy_buffer_size 128k;
            proxy_buffers 8 128k;
        }

        error_page 502 503 504 /cn-error.html;
        location = /cn-error.html {
            root /usr/share/nginx/cn-override;
            internal;
        }
    }

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }
}
NGINX_EOF

success "nginx configured"

# ─── Validate nginx config ──────────────────────────────────
info "Validating nginx configuration..."
nginx -t 2>&1 || error "nginx config validation failed — check logs above"
success "nginx config valid"

# ─── Wait for HA Core to be ready ──────────────────────────
info "Waiting for HA Core to be ready on port ${HA_PORT}..."
MAX_WAIT=120
WAITED=0
until curl -sf "http://127.0.0.1:${HA_PORT}/api/" > /dev/null 2>&1; do
    if [[ $WAITED -ge $MAX_WAIT ]]; then
        warn "HA Core not ready after ${MAX_WAIT}s — starting anyway"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [[ $WAITED -lt $MAX_WAIT ]]; then
    success "HA Core is ready"
fi

# ─── Start nginx ────────────────────────────────────────────
info "Starting Connect Nest..."
success "Connect Nest is running!"
info "  Ingress (HA sidebar): port ${INGRESS_PORT}"
info "  Direct access:        port 7080"
info ""

# Run nginx in foreground (required for Docker/add-on)
exec nginx -g "daemon off;"
