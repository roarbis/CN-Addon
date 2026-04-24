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
info "  Connect Nest v2025.3.6"
info "  Your smart home, beautifully connected."
info "============================================"

# ─── Ensure SUPERVISOR_TOKEN is available ──────────────────
# HA Supervisor writes the token to the s6 env dir.
# If it wasn't inherited (e.g. subshell quirks), load it explicitly.
if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    _TOKEN_FILE="/run/s6/container_environment/SUPERVISOR_TOKEN"
    if [[ -f "$_TOKEN_FILE" ]]; then
        SUPERVISOR_TOKEN=$(cat "$_TOKEN_FILE")
        export SUPERVISOR_TOKEN
        info "SUPERVISOR_TOKEN loaded from s6 env dir"
    else
        warn "SUPERVISOR_TOKEN not found — Supervisor API calls will fail (hassio_api may not be active)"
    fi
fi
info "SUPERVISOR_TOKEN present: $([[ -n "${SUPERVISOR_TOKEN:-}" ]] && echo yes || echo NO)"
info "HA backend port: ${HA_PORT}"
info "SSL enabled: ${SSL}"

# ─── Version check via Supervisor API ──────────────────────
# Check HA version for compatibility logging
HA_VERSION=$(curl -s \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN:-}" \
    http://supervisor/core/info 2>/dev/null \
    | jq -r '.data.version // "unknown"' 2>/dev/null) || HA_VERSION="unknown"

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

        # CN background image (bundled in Docker image)
        location = /cn-bg.jpg {
            alias /usr/share/nginx/cn-override/static/cn-bg.jpg;
            expires 30d;
            add_header Cache-Control "public";
        }

        # Onboarding wizard — API (proxied to Python backend on port 8098)
        location /onboarding/api/ {
            proxy_pass http://127.0.0.1:8098;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 300;
            proxy_send_timeout 300;
        }

        # Onboarding wizard — redirect no-trailing-slash to canonical URL
        location = /onboarding {
            return 301 /onboarding/;
        }

        # Onboarding wizard — static frontend
        # Use root (not alias) so that try_files resolves paths correctly
        location /onboarding/ {
            root /usr/share/nginx/cn-override;
            index index.html;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
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
            # Disable compression from backend so sub_filter can process content
            proxy_set_header Accept-Encoding "";

            # ── Runtime branding replacement ──────────────
            # Replaces ALL occurrences in proxied HTML/JS responses
            # Uses nginx built-in sub_filter (ngx_http_sub_module)
            sub_filter_once off;
            sub_filter 'Home Assistant' 'Connect Nest';
            sub_filter 'home-assistant' 'connect-nest';
            sub_filter '</head>' '<link rel="apple-touch-icon" sizes="180x180" href="/static/icons/cn-icon-180.png"><link rel="apple-touch-icon" sizes="152x152" href="/static/icons/cn-icon-152.png"><link rel="apple-touch-icon" sizes="120x120" href="/static/icons/cn-icon-120.png"><meta name="apple-mobile-web-app-title" content="Connect Nest"><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Raleway:wght@300;400;600;700&family=Baumans&display=swap"></head>';
            sub_filter_types text/html text/javascript application/javascript application/json;

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

        # CN background image (bundled in Docker image)
        location = /cn-bg.jpg {
            alias /usr/share/nginx/cn-override/static/cn-bg.jpg;
            expires 30d;
            add_header Cache-Control "public";
        }

        # Onboarding wizard — API (proxied to Python backend on port 8098)
        location /onboarding/api/ {
            proxy_pass http://127.0.0.1:8098;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_read_timeout 300;
            proxy_send_timeout 300;
        }

        # Onboarding wizard — redirect no-trailing-slash to canonical URL
        location = /onboarding {
            return 301 /onboarding/;
        }

        # Onboarding wizard — static frontend
        # Use root (not alias) so that try_files resolves paths correctly
        location /onboarding/ {
            root /usr/share/nginx/cn-override;
            index index.html;
            add_header Cache-Control "no-cache, no-store, must-revalidate";
        }

        location / {
            proxy_pass http://ha_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            # Disable compression from backend so sub_filter can process content
            proxy_set_header Accept-Encoding "";

            sub_filter_once off;
            sub_filter 'Home Assistant' 'Connect Nest';
            sub_filter 'home-assistant' 'connect-nest';
            sub_filter '</head>' '<link rel="apple-touch-icon" sizes="180x180" href="/static/icons/cn-icon-180.png"><link rel="apple-touch-icon" sizes="152x152" href="/static/icons/cn-icon-152.png"><link rel="apple-touch-icon" sizes="120x120" href="/static/icons/cn-icon-120.png"><meta name="apple-mobile-web-app-title" content="Connect Nest"><link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Raleway:wght@300;400;600;700&family=Baumans&display=swap"></head>';
            sub_filter_types text/html text/javascript application/javascript application/json;

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

# ─── First-run CN setup ─────────────────────────────────────
# Installs theme + card-mod into HA config on first start only
MARKER=/config/.cn_setup_done
if [[ ! -f "$MARKER" ]]; then
    info "First run — installing CN theme and card-mod..."

    # Copy card-mod.js to HA's local www directory
    mkdir -p /config/www
    cp /usr/share/nginx/cn-override/card-mod.js /config/www/card-mod.js
    info "card-mod.js copied to /config/www/"

    # Try registering card-mod via Lovelace resources API (no HA restart needed)
    LOVELACE_STATUS=""
    if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
        LOVELACE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
            -H "Content-Type: application/json" \
            -d '{"url": "/local/card-mod.js", "res_type": "module"}' \
            "http://supervisor/core/api/lovelace/resources" 2>/dev/null)
    fi

    if [[ "$LOVELACE_STATUS" =~ ^2 ]]; then
        success "card-mod registered via Lovelace API (no restart needed)"
    else
        warn "Lovelace API unavailable (${LOVELACE_STATUS:-no token}) — card-mod added to configuration.yaml"
        warn "Restart HA once for card-mod to take effect"
    fi

    # Copy CN dark theme to HA themes directory
    mkdir -p /config/themes
    cp /usr/share/nginx/cn-override/themes/cn_dark.yaml /config/themes/cn_dark.yaml
    success "CN dark theme installed to /config/themes/"

    # Add frontend: themes + extra_module_url to configuration.yaml if not present
    if ! grep -q "^frontend:" /config/configuration.yaml 2>/dev/null; then
        printf '\nfrontend:\n  themes: !include_dir_merge_named themes\n  extra_module_url:\n    - /local/card-mod.js\n' \
            >> /config/configuration.yaml
        info "Added frontend config to configuration.yaml"
    fi

    touch "$MARKER"
    success "CN setup complete"
fi

# Always reload themes (picks up theme file updates on version upgrades)
if [[ -n "${SUPERVISOR_TOKEN:-}" ]]; then
    curl -s -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        "http://supervisor/core/api/services/frontend/reload_themes" > /dev/null 2>&1 || true
fi

# ─── Wait for HA Core to be ready ──────────────────────────
info "Waiting for HA Core to be ready on port ${HA_PORT}..."
MAX_WAIT=120
WAITED=0
until curl -s --max-time 3 "http://127.0.0.1:${HA_PORT}/" -o /dev/null 2>&1; do
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

# ─── Start onboarding wizard backend ────────────────────────
info "Starting CN Onboarding Wizard backend..."

# Verify Python3 is available before attempting to start
if ! command -v python3 &>/dev/null; then
    warn "python3 not found — onboarding wizard will be unavailable"
    warn "Add python3 to apk packages in Dockerfile if wizard is needed"
else
    CN_HA_PORT="${HA_PORT}" \
        python3 /usr/share/nginx/cn-override/wizard/wizard.py \
        >> /proc/1/fd/1 2>&1 &
    WIZARD_PID=$!

    # Wait 2 seconds and confirm the process is still alive (not crashed at startup)
    sleep 2
    if kill -0 "${WIZARD_PID}" 2>/dev/null; then
        success "Wizard backend running (PID ${WIZARD_PID}) — access at /onboarding/"
    else
        warn "Wizard backend exited immediately — check logs above for Python errors"
        warn "Onboarding wizard will be unavailable until this is resolved"
    fi
fi

# ─── Start nginx ────────────────────────────────────────────
info "Starting Connect Nest..."
success "Connect Nest is running!"
info "  Ingress (HA sidebar): port ${INGRESS_PORT}"
info "  Direct access:        port 7080"
info "  Onboarding wizard:    /onboarding/"
info ""

# Run nginx in foreground (required for Docker/add-on)
exec nginx -g "daemon off;"
