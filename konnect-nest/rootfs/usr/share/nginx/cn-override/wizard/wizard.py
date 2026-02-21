#!/usr/bin/env python3
"""
Connect Nest Onboarding Wizard — Backend API Server
Runs on 127.0.0.1:8098, proxied by nginx at /onboarding/api/
"""
import json
import os
import time
import urllib.request
import urllib.error
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SUPERVISOR_TOKEN = os.environ.get('SUPERVISOR_TOKEN', '')
HA_PORT = int(os.environ.get('CN_HA_PORT', '8123'))
WIZARD_STATE_FILE = '/data/cn_wizard_state.json'

# ─── Supervisor / HA API helpers ────────────────────────────────

def _supervisor_req(method, path, body=None, timeout=60):
    url = f'http://supervisor{path}'
    headers = {
        'Authorization': f'Bearer {SUPERVISOR_TOKEN}',
        'Content-Type': 'application/json',
    }
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            body = json.loads(raw) if raw else {}
        except Exception:
            body = {'_raw': raw.decode('utf-8', errors='replace') if raw else ''}
        return e.code, body
    except Exception as e:
        return 0, {'error': str(e)}

def supervisor(method, path, body=None, timeout=60):
    return _supervisor_req(method, path, body, timeout)

def ha_core_api(method, path, body=None):
    """Call HA Core REST API via http://homeassistant (requires homeassistant_api: true).
    Uses a different base than the Supervisor proxy (/core/api) which does NOT
    forward authentication to HA Core and returns 401."""
    url = f'http://homeassistant/api{path}'
    headers = {
        'Authorization': f'Bearer {SUPERVISOR_TOKEN}',
        'Content-Type': 'application/json',
    }
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            bd = json.loads(raw) if raw else {}
        except Exception:
            bd = {}
        return e.code, bd
    except Exception as e:
        return 0, {'error': str(e)}

# ─── Wizard state persistence ────────────────────────────────────

def load_state():
    try:
        with open(WIZARD_STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_state(state):
    Path('/data').mkdir(parents=True, exist_ok=True)
    with open(WIZARD_STATE_FILE, 'w') as f:
        json.dump(state, f, indent=2)

# ─── Add-on helpers ──────────────────────────────────────────────

def addon_info(slug):
    status, resp = supervisor('GET', f'/addons/{slug}/info')
    return resp.get('data', {}) if status == 200 else {}

def addon_state(slug):
    info = addon_info(slug)
    return info.get('state', 'unknown')  # none/stopped/started/error

def install_addon(slug):
    status, _ = supervisor('POST', f'/addons/{slug}/install', timeout=120)
    return status in (200, 201)

def start_addon(slug):
    status, _ = supervisor('POST', f'/addons/{slug}/start')
    return status in (200, 201)

def set_addon_options(slug, options):
    status, _ = supervisor('POST', f'/addons/{slug}/options', {'options': options})
    return status in (200, 201)

def ensure_addon(slug, options=None):
    """Install if needed, optionally configure, then start."""
    state = addon_state(slug)
    if state == 'unknown':
        install_addon(slug)
        time.sleep(3)
    if options:
        set_addon_options(slug, options)
    if addon_state(slug) not in ('started', 'running'):
        start_addon(slug)
        time.sleep(2)

# ─── HACS installer ──────────────────────────────────────────────

def install_hacs_files():
    """Download latest HACS release zip and extract to /config/custom_components/hacs/."""
    req = urllib.request.Request(
        'https://api.github.com/repos/hacs/integration/releases/latest',
        headers={'User-Agent': 'ConnectNest-Wizard/1.0'}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
    version = data['tag_name']

    zip_url = f'https://github.com/hacs/integration/releases/download/{version}/hacs.zip'
    zip_path = Path('/tmp/hacs.zip')
    urllib.request.urlretrieve(zip_url, str(zip_path))

    hacs_dir = Path('/config/custom_components/hacs')
    hacs_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(hacs_dir)
    zip_path.unlink(missing_ok=True)
    return version

# ─── Z2M configuration writer ────────────────────────────────────

def write_z2m_config(coordinator_ip, coordinator_port, mqtt_user, mqtt_pass):
    Path('/config/zigbee2mqtt').mkdir(parents=True, exist_ok=True)
    cfg_path = Path('/config/zigbee2mqtt/configuration.yaml')
    # Only write if doesn't exist — preserve existing user config
    if cfg_path.exists():
        return False
    cfg = f"""# Zigbee2MQTT — generated by Connect Nest wizard
homeassistant: true
permit_join: false

mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://127.0.0.1
  user: {mqtt_user}
  password: "{mqtt_pass}"

serial:
  # SMlight SLZB-06 — network coordinator (EmberZNet/EZSP over TCP)
  port: tcp://{coordinator_ip}:{coordinator_port}
  adapter: ember

advanced:
  log_level: info

frontend: true
"""
    cfg_path.write_text(cfg)
    return True

# ─── HA restart + wait ───────────────────────────────────────────

def restart_ha_and_wait(timeout=240):
    supervisor('POST', '/core/restart')
    time.sleep(8)  # Give HA time to begin shutdown
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            # Use Supervisor /core/info — pure Supervisor API, no HA auth needed
            status, data = supervisor('GET', '/core/info', timeout=10)
            if status == 200 and (data.get('data') or {}).get('version'):
                return True
        except Exception:
            pass
        time.sleep(4)
    return False

# ─── HTTP Handler ────────────────────────────────────────────────

class WizardHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # Suppress request logging (nginx handles that)

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def parse_body(self):
        length = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(length)) if length else {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    # ── GET endpoints ──────────────────────────────────────────

    def do_GET(self):
        path = self.path.split('?')[0]
        try:
            self._do_GET(path)
        except Exception as e:
            self.send_json(500, {'error': str(e), 'type': type(e).__name__})

    def _do_GET(self, path):
        if path == '/onboarding/api/status':
            state = load_state()
            # Use Supervisor /core/info — pure Supervisor endpoint, no HA auth needed.
            # Do NOT use /core/api/... which proxies to HA Core and returns 401.
            _, info = supervisor('GET', '/core/info')
            version = (info.get('data') or {}).get('version', 'unknown')
            self.send_json(200, {
                'ha_version': version,
                'ha_online': version != 'unknown',
                'supervisor_token': bool(SUPERVISOR_TOKEN),
                'wizard_state': state,
            })

        elif path.startswith('/onboarding/api/addon/'):
            slug = path.rstrip('/').split('/')[-1]
            info = addon_info(slug)
            self.send_json(200, {
                'installed': bool(info),
                'state': info.get('state', 'unknown'),
                'version': info.get('version', ''),
                'name': info.get('name', slug),
            })

        else:
            self.send_json(404, {'error': 'not found'})

    # ── POST endpoints ─────────────────────────────────────────

    def do_POST(self):
        path = self.path.split('?')[0]
        try:
            body = self.parse_body()
            state = load_state()
            self._do_POST(path, body, state)
        except Exception as e:
            self.send_json(500, {'ok': False, 'error': str(e), 'type': type(e).__name__})

    def _do_POST(self, path, body, state):

        # ── Step: Studio Code Server ──
        if path == '/onboarding/api/step/studio-code':
            slug = 'a0d7b954_vscode'
            try:
                ensure_addon(slug)
                state['studio_code'] = 'done'
                save_state(state)
                self.send_json(200, {'ok': True, 'message': 'Studio Code Server installed and started'})
            except Exception as e:
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: HACS files ──
        elif path == '/onboarding/api/step/hacs':
            hacs_path = Path('/config/custom_components/hacs')
            if hacs_path.exists() and list(hacs_path.iterdir()):
                state['hacs_files'] = 'already_installed'
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': 'HACS already installed',
                    'needs_restart': False,
                })
            else:
                try:
                    version = install_hacs_files()
                    state['hacs_files'] = version
                    save_state(state)
                    self.send_json(200, {
                        'ok': True,
                        'message': f'HACS {version} files installed — HA restart required to activate',
                        'needs_restart': True,
                    })
                except Exception as e:
                    self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: HA restart + wait ──
        elif path == '/onboarding/api/step/restart':
            ready = restart_ha_and_wait(timeout=240)
            state['last_restart'] = time.time()
            save_state(state)
            self.send_json(200, {
                'ok': ready,
                'message': 'HA restarted and ready' if ready else 'HA restart timed out — check HA logs',
            })

        # ── Step: MQTT broker ──
        elif path == '/onboarding/api/step/mqtt':
            mqtt_user = body.get('username', 'cn_mqtt')
            mqtt_pass = body.get('password', '')
            if not mqtt_pass:
                self.send_json(400, {'ok': False, 'error': 'MQTT password is required'})
                return

            try:
                slug = 'core_mosquitto'
                ensure_addon(slug, options={
                    'logins': [{'username': mqtt_user, 'password': mqtt_pass}],
                    'customize': {'active': False, 'folder': 'mosquitto'},
                    'certfile': 'fullchain.pem',
                    'keyfile': 'privkey.pem',
                })
                # Wait for Mosquitto to be fully ready before Z2M tries to connect
                time.sleep(5)

                state['mqtt'] = {'username': mqtt_user, 'done': True}
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': 'Mosquitto MQTT Broker installed, configured and running',
                    'note': 'HA will auto-discover Mosquitto — accept the integration prompt in HA',
                })
            except Exception as e:
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: Zigbee2MQTT ──
        elif path == '/onboarding/api/step/zigbee':
            coordinator_ip = body.get('coordinator_ip', '').strip()
            coordinator_port = int(body.get('coordinator_port', 6638))
            mqtt_user = body.get('mqtt_username') or state.get('mqtt', {}).get('username', 'cn_mqtt')
            mqtt_pass = body.get('mqtt_password', '')

            if not coordinator_ip:
                self.send_json(400, {'ok': False, 'error': 'Zigbee coordinator IP is required'})
                return
            if not mqtt_pass:
                self.send_json(400, {'ok': False, 'error': 'MQTT password is required'})
                return

            try:
                # 1. Add Z2M custom repository
                supervisor('POST', '/store/repositories', {
                    'repository': 'https://github.com/zigbee2mqtt/hassio-zigbee2mqtt'
                })
                time.sleep(3)  # Allow Supervisor to index the new repo

                # 2. Install Z2M add-on
                z2m_slug = '45df7312_zigbee2mqtt'
                state_before = addon_state(z2m_slug)
                if state_before == 'unknown':
                    install_addon(z2m_slug)
                    time.sleep(5)

                # 3. Write Z2M configuration.yaml (EmberZNet/SLZB-06 via TCP)
                write_z2m_config(coordinator_ip, coordinator_port, mqtt_user, mqtt_pass)

                # 4. Start Z2M — MQTT must already be running (enforced by wizard step order)
                if addon_state(z2m_slug) not in ('started', 'running'):
                    start_addon(z2m_slug)

                state['zigbee'] = {'coordinator_ip': coordinator_ip, 'port': coordinator_port, 'done': True}
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': f'Zigbee2MQTT installed and configured (SLZB-06 at {coordinator_ip}:{coordinator_port})',
                })
            except Exception as e:
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: Tailscale ──
        elif path == '/onboarding/api/step/tailscale':
            try:
                slug = 'a0d7b954_tailscale'
                ensure_addon(slug, options={
                    'accept_dns': True,
                    'accept_routes': False,
                    'advertise_exit_node': False,
                    'advertise_routes': [],
                    'funnel': False,
                    'log_level': 'info',
                    'login_server': '',
                    'proxy': False,
                    'snat_subnet_routes': True,
                    'tags': [],
                    'taildrop': True,
                    'userspace_networking': True,
                })
                state['tailscale'] = 'done'
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': 'Tailscale installed and starting',
                    'action_required': True,
                    'instructions': 'Open the Tailscale add-on log in HA and click the authentication URL shown to link your Tailscale account.',
                })
            except Exception as e:
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: HA Backup schedule ──
        elif path == '/onboarding/api/step/backup':
            schedule = body.get('schedule', 'daily')   # daily / weekly / never
            copies = int(body.get('copies', 3))

            # HA 2024.6+ native backup schedule API
            # Uses ha_core_api (http://homeassistant) — requires homeassistant_api: true
            ha_core_api('POST', '/backup/config/update', {
                'schedule': {'state': schedule},
                'retention': {'copies': copies},
            })

            state['backup'] = {'schedule': schedule, 'copies': copies, 'done': True}
            save_state(state)
            self.send_json(200, {
                'ok': True,
                'message': f'Backup configured: {schedule}, keep {copies} copies',
            })

        # ── Step: OneDrive Backup (optional, informational) ──
        elif path == '/onboarding/api/step/onedrive':
            hacs_path = Path('/config/custom_components/hacs')
            if not hacs_path.exists():
                self.send_json(200, {
                    'ok': False,
                    'skippable': True,
                    'message': 'HACS is not installed — OneDrive Backup requires HACS. Install HACS first, then add OneDrive Backup from the HACS integrations store.',
                })
                return
            # Cannot automate: HACS integration install + Microsoft OAuth must be done in HA UI
            state['onedrive'] = 'follow_up'
            save_state(state)
            self.send_json(200, {
                'ok': True,
                'manual_required': True,
                'message': 'OneDrive Backup recorded as a follow-up task',
                'instructions': 'HACS → Integrations → search "OneDrive Backup" → install → restart HA → Settings → Integrations → OneDrive Backup → Configure → sign in with Microsoft.',
            })

        # ── Step: complete ──
        elif path == '/onboarding/api/step/complete':
            state['wizard_complete'] = True
            state['completed_at'] = time.time()
            save_state(state)
            self.send_json(200, {'ok': True, 'message': 'Connect Nest setup complete!'})

        else:
            self.send_json(404, {'error': 'not found'})


# ─── Entry point ─────────────────────────────────────────────────

if __name__ == '__main__':
    server = HTTPServer(('127.0.0.1', 8098), WizardHandler)
    print('[CN Wizard] Backend API listening on port 8098', flush=True)
    server.serve_forever()
