# PART 4 — Zigbee2MQTT

> **Time:** ~10 minutes setup + pairing time per device
> **Previous step:** Part 3 complete — MQTT broker running
> **What is Zigbee2MQTT?** Bridges your Zigbee USB dongle to MQTT,
> making all Zigbee devices available in HA automatically.

---

## What You're Building

```
Zigbee Devices (bulbs, sensors, switches, plugs)
        │
        │  Zigbee radio (2.4GHz mesh)
        ▼
  USB Dongle (plugged into Windows host → passed to VM)
        │
        │  /dev/ttyUSB0 or /dev/ttyACM0
        ▼
  Zigbee2MQTT add-on
        │
        │  MQTT messages → topic: zigbee2mqtt/#
        ▼
  Mosquitto MQTT broker
        │
        ▼
  Home Assistant  (devices appear automatically)
```

---

## 4.1 — Supported Zigbee USB Dongles

Zigbee2MQTT supports 100+ adapters. The most recommended:

| Dongle | Price | Notes |
|---|---|---|
| **SONOFF Zigbee 3.0 USB Dongle Plus** (CC2652P) | ~$20 | ✅ Best value, plug & play |
| **SMLIGHT SLZB-07** | ~$25 | ✅ Excellent, widely used |
| **ITead USB Zigbee Dongle** | ~$15 | ✅ Budget option, works well |
| **ConBee II** (Dresden Elektronik) | ~$40 | ✅ Premium, very reliable |
| **Aeotec Z-Stick 7** | ~$50 | Z-Wave (different protocol — see note) |

> **Z-Wave vs Zigbee:** These are different protocols. Zigbee2MQTT handles
> Zigbee only. For Z-Wave devices, use the **Z-Wave JS add-on** separately.
> Both can coexist — one USB dongle per protocol.

---

## 4.2 — USB Dongle Passthrough to VMware VM

This is the VMware-specific step — you must do this before Zigbee2MQTT can see the dongle.

### On Windows Host:
1. Plug the Zigbee USB dongle into a USB port on the host machine
2. Windows may install a driver automatically (normal)
3. In Device Manager: look for the dongle under **Ports (COM & LPT)**
   or **Universal Serial Bus devices**
   - SONOFF dongle appears as: "Silicon Labs CP210x USB to UART Bridge"
   - Note the COM port: e.g., `COM3`

### In VMware Workstation:
1. The VM must be **running**
2. In VMware menu bar: **VM → Removable Devices**
3. Find your dongle (e.g., "Silicon Labs CP210x USB to UART Bridge")
4. Click → **Connect (Disconnect from Host)**
5. The dongle **disappears from Windows** and appears in the Ubuntu VM

### Verify in Ubuntu VM:
```bash
# SSH into VM
ssh knadmin@192.168.1.XXX

# Check if dongle is detected
ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
# Should show: /dev/ttyUSB0  OR  /dev/ttyACM0

# Get more details about the device
lsusb | grep -i "silicon\|cp210\|ch340\|sonoff\|zigbee"
# Should show your dongle

# Check device permissions
ls -la /dev/ttyUSB0
# Should show: crw-rw---- 1 root dialout
# The "dialout" group is important
```

### Grant VM User Access to the Serial Port:
```bash
sudo usermod -aG dialout knadmin
# Log out and back in for this to take effect
```

---

## 4.3 — Note Your Dongle's Device Path

The path is needed for Zigbee2MQTT configuration:

```bash
# Most reliable method — by ID (doesn't change between reboots)
ls /dev/serial/by-id/
# Example output:
# usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_XXXXX-if00-port0

# This is your stable device path:
# /dev/serial/by-id/usb-ITead_Sonoff_Zigbee_3.0_USB_Dongle_Plus_XXXXX-if00-port0
```

> ⚠️ Always use the `/dev/serial/by-id/...` path, NOT `/dev/ttyUSB0`.
> The ttyUSB number can change between reboots. The by-id path never changes.

---

## 4.4 — Make USB Passthrough Persistent

So the dongle is always connected to the VM (not Windows) after each reboot:

### In VMware Workstation:
1. VM Settings → **USB Controller**
2. Click **"Add..."** → **USB Device**
3. Select your dongle from the list
4. ✅ This creates a USB filter — VMware auto-connects it to VM on plug-in

---

## 4.5 — Install Zigbee2MQTT Add-on

Zigbee2MQTT is not in the default HA add-on store — you add it via a community repository.

### Add the Zigbee2MQTT Repository:
1. **Settings → Add-ons → Add-on Store**
2. Click **⋮ menu** (top right) → **Repositories**
3. Add: `https://github.com/zigbee2mqtt/hassio-zigbee2mqtt`
4. Click **Add → Close**
5. Page refreshes — scroll down to find **"Zigbee2MQTT"** section

### Install:
1. Click **"Zigbee2MQTT"** (the main one, not Edge)
2. Click **Install** (~2 minutes)

---

## 4.6 — Configure Zigbee2MQTT

Click the **Configuration** tab and fill in:

```yaml
data_path: /config/zigbee2mqtt
socat:
  enabled: false
  master: pty,raw,echo=0
  slave: tcp-listen:8485,keepalive,nodelay,reuseaddr,keepidle=1,keepintvl=1,keepcnt=5
  options: "-d -d"
  log: false
```

Then click **"Edit in YAML"** (or use the form) and set the full config:

> **Important:** Replace the serial port path and MQTT password with yours.

```yaml
# Zigbee2MQTT Configuration
# Full config reference: https://www.zigbee2mqtt.io/guide/configuration/

mqtt:
  server: mqtt://localhost:1883
  user: mqtt_user
  password: "YOUR_MQTT_PASSWORD"   # ← from Part 3
  base_topic: zigbee2mqtt

serial:
  port: /dev/serial/by-id/YOUR_DONGLE_PATH   # ← from step 4.3
  # Common alternatives if by-id doesn't work:
  # port: /dev/ttyUSB0
  # port: /dev/ttyACM0
  adapter: auto    # auto-detects: zstack, deconz, ezsp, etc.

# Web frontend (access Zigbee2MQTT UI in browser)
frontend:
  enabled: true
  port: 8080
  auth_token: ""   # Leave empty for LAN-only access (safe on home network)

# Home Assistant integration via MQTT Discovery
homeassistant:
  enabled: true

# Permit devices to join (pairing mode)
# Set to true temporarily when adding new devices
# Set to false normally (security)
permit_join: false

# Advanced settings
advanced:
  log_level: info          # debug for troubleshooting, info for normal use
  pan_id: GENERATE         # auto-generates a unique PAN ID
  channel: 11              # Zigbee channel (11-26). Avoid 11,15,20,25 if near WiFi
  network_key: GENERATE    # auto-generates a unique network key
  last_seen: ISO_8601      # timestamp format for device last-seen

# Device availability tracking
availability:
  enabled: true
  active:
    timeout: 10    # minutes before device marked unavailable
  passive:
    timeout: 1500  # minutes (25 hours) for battery devices
```

Click **Save**

---

## 4.7 — Start Zigbee2MQTT

1. Click **Info** tab
2. **Start on boot** → ON
3. **Watchdog** → ON
4. Click **Start**

Check **Log** tab:
```
Zigbee2MQTT:info  2025-01-XX ... Starting Zigbee2MQTT version X.X.X
Zigbee2MQTT:info  ... Connecting to MQTT server
Zigbee2MQTT:info  ... Connected to MQTT server
Zigbee2MQTT:info  ... Starting zigbee-herdsman
Zigbee2MQTT:info  ... Coordinator firmware version: {type: 'ZNSP', meta: {...}}
Zigbee2MQTT:info  ... Currently 0 devices are joined
Zigbee2MQTT:info  ... Zigbee2MQTT started!
```

✅ If you see "Zigbee2MQTT started!" — it's working.

---

## 4.8 — Access Zigbee2MQTT Web UI

Open browser:
```
http://192.168.1.XXX:8080
```

You'll see the Zigbee2MQTT dashboard:
- Device list (empty until you pair devices)
- Map view
- Settings
- Log viewer

---

## 4.9 — Pairing Zigbee Devices

### Enable Pairing Mode:

**Method 1 — Via Zigbee2MQTT UI:**
1. Open `http://192.168.1.XXX:8080`
2. Click **"Permit join (All)"** button (top right)
3. A 3-minute countdown starts

**Method 2 — Via HA:**
1. **Developer Tools → Services**
2. Service: `mqtt.publish`
3. Payload:
```yaml
topic: zigbee2mqtt/bridge/request/permit_join
payload: '{"value": true, "time": 180}'
```

### Pair a Device:
Each device has its own pairing method — consult the device manual.
Common methods:
- **Bulbs:** Power cycle 5-6 times rapidly
- **Sensors/switches:** Hold pairing button for 5-10 seconds
- **Plugs:** Hold button until light flashes

### Confirm Pairing:
In Zigbee2MQTT logs you'll see:
```
Zigbee2MQTT:info  Device joined (0x1234567890abcdef)
Zigbee2MQTT:info  IKEA TRADFRI bulb E14 (0x1234567890abcdef) interviewed OK
Zigbee2MQTT:info  Device successfully interviewed '0x1234567890abcdef'
```

In HA: **Settings → Devices & Services → MQTT** — new devices appear automatically!

### Rename Devices (Important):
In Zigbee2MQTT UI → click device → **Rename**
Use descriptive names: `living_room_lamp`, `front_door_sensor`, `kitchen_plug`

These names become the entity IDs in HA.

---

## 4.10 — Disable Pairing Mode When Done

**Always** disable permit_join after pairing:
```
Zigbee2MQTT UI → "Permit join" button → OFF
```
Security best practice — don't leave pairing open.

---

## 4.11 — Troubleshooting

### "Error: Failed to connect to the adapter"
```bash
# Check dongle is visible in VM
ls /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/

# Check permissions
groups knadmin  # should include dialout

# Check VMware USB connection
# VMware → VM → Removable Devices → [dongle] → Connected?
```

### "MQTT connection refused"
- Verify Mosquitto is running (Part 3)
- Check username/password in Zigbee2MQTT config matches Mosquitto config
- Verify: `mosquitto_sub -h localhost -u mqtt_user -P password -t '#' -v`

### Device not pairing
- Make sure permit_join is ON (3-minute window)
- Keep device within 2 metres of USB dongle during pairing
- Try factory reset on the device first
- Check Zigbee2MQTT supports your device: https://www.zigbee2mqtt.io/supported-devices/

### Wrong Zigbee channel
If you have WiFi interference (common):
- Change `channel` in config to `25` (furthest from 2.4GHz WiFi)
- Restart Zigbee2MQTT (this will re-pair all devices — plan accordingly)

---

## 4.12 — Take a Snapshot

```
HA: Settings → Backups → Create backup
Name: 03-zigbee2mqtt-working

VMware: Snapshot → Take Snapshot
Name: 03-zigbee2mqtt-devices-paired
Description: MQTT + Zigbee2MQTT running, X devices paired
```

---

## ✅ Part 4 Complete

| Check | Status |
|---|---|
| USB dongle visible in VM (`/dev/serial/by-id/...`) | ☐ |
| VMware USB filter set (auto-reconnect) | ☐ |
| Zigbee2MQTT add-on installed and running | ☐ |
| Connected to MQTT broker | ☐ |
| Zigbee2MQTT Web UI accessible at :8080 | ☐ |
| At least one test device paired | ☐ |
| Device visible in HA (Settings → Devices) | ☐ |
| Permit join disabled | ☐ |
| Snapshot taken | ☐ |

**→ Next: [PART-5-KN-ADDON.md](PART-5-KN-ADDON.md)**
