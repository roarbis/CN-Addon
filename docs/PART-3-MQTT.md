# PART 3 — Mosquitto MQTT Broker

> **Time:** ~5 minutes
> **Previous step:** Part 2 complete — HA is stable and healthy
> **What is MQTT?** A lightweight messaging protocol. Zigbee2MQTT uses it
> to talk to HA. Many smart home devices (bulbs, sensors, switches) also
> speak MQTT natively.

---

## What You're Installing

```
Smart Devices / Zigbee2MQTT
        │
        │  MQTT messages (publish/subscribe)
        ▼
  Mosquitto Broker   :1883   ← this is what we're installing
        │
        │  HA MQTT Integration
        ▼
  Home Assistant     :8123   ← reads device states, triggers automations
```

Mosquitto is the standard MQTT broker for HA. It runs as a native HA add-on
so it's managed entirely from the HA UI — no SSH needed.

---

## 3.1 — Install Mosquitto Add-on

1. In HA: **Settings → Add-ons → Add-on Store**
2. Search: **"Mosquitto broker"**
3. Click the official **"Mosquitto broker"** add-on (by Home Assistant)
4. Click **Install** (takes ~1 minute)

---

## 3.2 — Configure Mosquitto

Click the **Configuration** tab:

```yaml
logins:
  - username: mqtt_user
    password: "YOUR_STRONG_PASSWORD_HERE"
require_certificate: false
certfile: fullchain.pem
keyfile: privkey.pem
customize:
  active: false
  folder: mosquitto
```

> 🔐 **Password rules:**
> - Minimum 12 characters
> - Mix of letters, numbers, symbols
> - **Write it down** — you'll need it for Zigbee2MQTT and HA integration
> - Example: `Mq$Secure2025!`

Click **Save**

---

## 3.3 — Start Mosquitto

1. Click the **Info** tab
2. Toggle **"Start on boot"** → ON
3. Toggle **"Watchdog"** → ON
4. Click **Start**
5. Click **Log** tab — you should see:

```
[Mosquitto] Starting MQTT broker
[Mosquitto] mosquitto version 2.x.x starting
[Mosquitto] Config loaded from /etc/mosquitto/mosquitto.conf
[Mosquitto] Opening ipv4 listen socket on port 1883
[Mosquitto] mosquitto version 2.x.x running
```

✅ Green status = running

---

## 3.4 — Configure HA MQTT Integration

HA needs to be told about the MQTT broker. Usually HA auto-discovers it.

**Check if auto-discovered:**
1. **Settings → Devices & Services**
2. Look for **"MQTT"** in the list
3. If it shows "Configure" → click it and it auto-connects

**If not auto-discovered — add manually:**
1. **Settings → Devices & Services → Add Integration**
2. Search: **"MQTT"**
3. Click **MQTT**
4. Fill in:

| Field | Value |
|---|---|
| Broker | `localhost` (or `127.0.0.1`) |
| Port | `1883` |
| Username | `mqtt_user` |
| Password | your Mosquitto password |

5. Click **Submit**
6. You should see **"MQTT connected successfully"**

---

## 3.5 — Test MQTT is Working

### From HA Developer Tools

1. **Developer Tools → MQTT** (the MQTT tab)
2. **Subscribe to topic:** `test/connectnest`
3. Click **Start Listening**
4. In another browser tab: **Publish**
   - Topic: `test/connectnest`
   - Payload: `hello`
5. You should see **"hello"** appear in the listener

✅ MQTT is working end-to-end.

### From Command Line (optional deeper test)
```bash
# SSH into VM
ssh knadmin@192.168.1.XXX

# Install mosquitto clients for testing
sudo apt-get install -y mosquitto-clients

# Subscribe (in one terminal)
mosquitto_sub -h localhost -p 1883 \
    -u mqtt_user -P "YOUR_PASSWORD" \
    -t "test/#" -v

# Publish (in another SSH session)
mosquitto_pub -h localhost -p 1883 \
    -u mqtt_user -P "YOUR_PASSWORD" \
    -t "test/hello" -m "Connect Nest MQTT working"

# You should see the message appear in the subscriber window
```

---

## 3.6 — MQTT Credentials Record

```
┌─────────────────────────────────────────┐
│  MQTT Broker — Connection Details       │
│                                         │
│  Host:     192.168.1.XXX (VM IP)        │
│  Port:     1883                         │
│  Username: mqtt_user                    │
│  Password: _______________________      │
│                                         │
│  Internal (within VM): localhost:1883   │
└─────────────────────────────────────────┘
```

**Store these credentials safely** — you'll enter them in Zigbee2MQTT next.

---

## 3.7 — Take a Snapshot

```
HA: Settings → Backups → Create backup
Name: 02-mosquitto-working

VMware: Snapshot → Take Snapshot
Name: 02-mosquitto-working
```

---

## ✅ Part 3 Complete

| Check | Status |
|---|---|
| Mosquitto add-on installed and running | ☐ |
| MQTT credentials noted | ☐ |
| HA MQTT integration connected | ☐ |
| MQTT test publish/subscribe working | ☐ |
| Snapshot taken | ☐ |

**→ Next: [PART-4-ZIGBEE2MQTT.md](PART-4-ZIGBEE2MQTT.md)**
