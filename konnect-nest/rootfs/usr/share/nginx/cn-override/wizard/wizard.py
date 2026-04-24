#!/usr/bin/env python3
"""
Connect Nest Onboarding Wizard — Backend API Server
Runs on 127.0.0.1:8098, proxied by nginx at /onboarding/api/
"""
import json
import os
import socket
import time
import urllib.request
import urllib.error
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SUPERVISOR_TOKEN = os.environ.get('SUPERVISOR_TOKEN', '')
HA_PORT = int(os.environ.get('CN_HA_PORT', '8123'))
WIZARD_STATE_FILE = '/data/cn_wizard_state.json'

# ─── TCP health check ────────────────────────────────────────────

def _ha_tcp_alive():
    """Check if HA Core is accepting TCP connections on its port.
    Works independently of SUPERVISOR_TOKEN — relies on host_network: true."""
    try:
        s = socket.create_connection(('127.0.0.1', HA_PORT), timeout=3)
        s.close()
        return True
    except Exception:
        return False

def _ha_http_alive():
    """HTTP check via the homeassistant hostname (proper add-on DNS).
    Any HTTP response — even 401 Unauthorized — means HA Core is listening.
    Requires homeassistant_api: true in config.yaml."""
    try:
        status, _ = ha_core_api('GET', '/')
        return status > 0
    except Exception:
        return False

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
    status, resp = supervisor('POST', f'/addons/{slug}/install', timeout=300)
    ok = status in (200, 201)
    if not ok:
        print(f'[CN Wizard] install_addon({slug}) failed: status={status} resp={resp}', flush=True)
    return ok

def start_addon(slug):
    status, resp = supervisor('POST', f'/addons/{slug}/start')
    ok = status in (200, 201)
    if not ok:
        print(f'[CN Wizard] start_addon({slug}) failed: status={status} resp={resp}', flush=True)
    return ok

def set_addon_options(slug, options):
    status, resp = supervisor('POST', f'/addons/{slug}/options', {'options': options})
    ok = status in (200, 201)
    if not ok:
        print(f'[CN Wizard] set_addon_options({slug}) failed: status={status} resp={resp}', flush=True)
    return ok

def ensure_addon(slug, options=None, verify_timeout=30):
    """Install if needed, optionally configure, then start.
    Returns (ok, final_state). Raises RuntimeError on install or start failure."""
    state = addon_state(slug)
    if state == 'unknown':
        if not install_addon(slug):
            raise RuntimeError(f'Install failed for add-on {slug} (check Supervisor logs)')
        time.sleep(3)
        # Wait for Supervisor to register the new addon
        deadline = time.time() + 30
        while addon_state(slug) == 'unknown' and time.time() < deadline:
            time.sleep(2)
        if addon_state(slug) == 'unknown':
            raise RuntimeError(f'Add-on {slug} did not appear after install')
    if options:
        set_addon_options(slug, options)
    if addon_state(slug) not in ('started', 'running'):
        if not start_addon(slug):
            raise RuntimeError(f'Start failed for add-on {slug}')
        # Verify it actually reached started state
        deadline = time.time() + verify_timeout
        while time.time() < deadline:
            if addon_state(slug) in ('started', 'running'):
                return True, addon_state(slug)
            time.sleep(2)
        final = addon_state(slug)
        raise RuntimeError(f'Add-on {slug} did not reach started state (current: {final})')
    return True, addon_state(slug)

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
    print(f'[CN Wizard] Downloading HACS {version} from {zip_url}', flush=True)
    urllib.request.urlretrieve(zip_url, str(zip_path))

    hacs_dir = Path('/config/custom_components/hacs')
    hacs_dir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(hacs_dir)
    zip_path.unlink(missing_ok=True)
    return version

# ─── Z2M configuration writer ────────────────────────────────────

def write_z2m_config(coordinator_ip, coordinator_port, mqtt_user, mqtt_pass, adapter='zstack'):
    Path('/config/zigbee2mqtt').mkdir(parents=True, exist_ok=True)
    cfg_path = Path('/config/zigbee2mqtt/configuration.yaml')
    # Only write if doesn't exist — preserve existing user config
    if cfg_path.exists():
        return False
    adapter_comment = {
        'zstack': 'ZStack (CC2652) via TCP',
        'ember':  'EmberZNet/EZSP via TCP',
        'deconz': 'deCONZ (ConBee) via TCP',
    }.get(adapter, adapter)
    cfg = f"""# Zigbee2MQTT — generated by Connect Nest wizard
homeassistant: true
permit_join: false

mqtt:
  base_topic: zigbee2mqtt
  server: mqtt://127.0.0.1
  user: {mqtt_user}
  password: "{mqtt_pass}"

serial:
  # SMlight SLZB-06 — network coordinator ({adapter_comment})
  port: tcp://{coordinator_ip}:{coordinator_port}
  adapter: {adapter}

advanced:
  log_level: info

frontend: true
"""
    cfg_path.write_text(cfg)
    return True

# ─── HA restart + wait ───────────────────────────────────────────

def trigger_ha_restart():
    """Fire-and-forget HA restart. Returns immediately so frontend can poll status.
    (The wizard backend itself restarts with HA, so we cannot block here.)"""
    status, resp = supervisor('POST', '/core/restart')
    print(f'[CN Wizard] trigger_ha_restart: status={status}', flush=True)
    return status in (200, 201)

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

            # Check 1: TCP connect to 127.0.0.1:HA_PORT (host_network: true required)
            tcp_alive = _ha_tcp_alive()

            # Check 2: HTTP GET http://homeassistant/api/ (any response = alive)
            http_alive = _ha_http_alive()

            # Check 3: Supervisor /core/info for HA version string
            sup_status, info = supervisor('GET', '/core/info')
            version = (info.get('data') or {}).get('version', 'unknown')

            # HA is online if ANY check succeeds
            ha_online = tcp_alive or http_alive or (version != 'unknown')

            diag = {
                'tcp': tcp_alive,
                'http': http_alive,
                'sup': sup_status,
                'ver': version,
                'token': bool(SUPERVISOR_TOKEN),
            }
            print(f'[CN Wizard] /status: {diag}', flush=True)

            self.send_json(200, {
                'ha_version': version,
                'ha_online': ha_online,
                'supervisor_token': bool(SUPERVISOR_TOKEN),
                'wizard_state': state,
                '_diag': diag,
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
                print(f'[CN Wizard] Studio Code install failed: {type(e).__name__}: {e}', flush=True)
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
                    print(f'[CN Wizard] HACS install failed: {type(e).__name__}: {e}', flush=True)
                    self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: HA restart (fire-and-forget; frontend polls /api/status) ──
        elif path == '/onboarding/api/step/restart':
            ok = trigger_ha_restart()
            state['last_restart'] = time.time()
            save_state(state)
            self.send_json(200, {
                'ok': ok,
                'restarting': ok,
                'message': 'HA restart triggered — the wizard backend will briefly go offline, then this page will reconnect automatically.' if ok else 'Failed to trigger HA restart — check Supervisor logs',
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
                print(f'[CN Wizard] MQTT step failed: {type(e).__name__}: {e}', flush=True)
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: Zigbee2MQTT ──
        elif path == '/onboarding/api/step/zigbee':
            coordinator_ip = body.get('coordinator_ip', '').strip()
            coordinator_port = int(body.get('coordinator_port', 6638))
            adapter = (body.get('adapter') or 'zstack').strip().lower()
            if adapter not in ('zstack', 'ember', 'deconz'):
                adapter = 'zstack'
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

                # 3. Write Z2M configuration.yaml (SLZB-06 via TCP, chosen adapter)
                write_z2m_config(coordinator_ip, coordinator_port, mqtt_user, mqtt_pass, adapter=adapter)

                # 4. Start Z2M — MQTT must already be running (enforced by wizard step order)
                if addon_state(z2m_slug) not in ('started', 'running'):
                    start_addon(z2m_slug)

                state['zigbee'] = {'coordinator_ip': coordinator_ip, 'port': coordinator_port, 'adapter': adapter, 'done': True}
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': f'Zigbee2MQTT installed and configured ({adapter} via SLZB-06 at {coordinator_ip}:{coordinator_port})',
                })
            except Exception as e:
                print(f'[CN Wizard] Zigbee step failed: {type(e).__name__}: {e}', flush=True)
                self.send_json(500, {'ok': False, 'error': str(e)})

        # ── Step: Tailscale ──
        elif path == '/onboarding/api/step/tailscale':
            slug = 'a0d7b954_tailscale'
            try:
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
                final_state = addon_state(slug)
                state['tailscale'] = {'status': 'installed', 'addon_state': final_state}
                save_state(state)
                self.send_json(200, {
                    'ok': True,
                    'message': f'Tailscale installed — add-on state: {final_state}',
                    'action_required': True,
                    'instructions': 'Open the Tailscale add-on log in HA and click the authentication URL shown to link your Tailscale account.',
                })
            except Exception as e:
                print(f'[CN Wizard] Tailscale install failed: {type(e).__name__}: {e}', flush=True)
                state['tailscale'] = {'status': 'failed', 'error': str(e)}
                save_state(state)
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
