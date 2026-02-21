# PART 2 — Home Assistant Barebone Install & Configuration

> **Time:** ~20 minutes
> **Previous step:** Part 1 complete, bootstrap.sh has run, HA is responding
> **Goal:** Stable, configured HA instance — tested before adding anything else

---

## 2.1 — Run the Bootstrap Script

If you haven't already run the bootstrap script:

```bash
# Copy script to VM
scp "C:\Temp\ClaudeCode\HA-KN-Fork\CN-Addon\scripts\bootstrap-vmware.sh" \
    knadmin@192.168.1.XXX:~/

# SSH into VM and run it
ssh knadmin@192.168.1.XXX
chmod +x ~/bootstrap-vmware.sh
sudo ~/bootstrap-vmware.sh
```

The script will:
- Prompt you about static IP (set it here — saves hassle later)
- Install Docker, HA OS Agent, HA Supervised automatically
- Tell you when HA is ready

---

## 2.2 — HA Onboarding Wizard

Open browser on your admin machine:
```
http://192.168.1.XXX:8123
```

> If you see a blank page or loading spinner, wait 5 minutes — HA is
> still pulling Docker images (~1GB on first start).

### Screen 1 — Create Account
| Field | Value |
|---|---|
| Name | Your name (this is display name only) |
| Username | `admin` |
| Password | Strong — **write it down** |
| Confirm password | Same |

Click **Create Account**

### Screen 2 — Home Location
- Type your friend's suburb/city
- Select from dropdown
- This sets timezone and sunrise/sunset times for automations
- Click **Next**

### Screen 3 — Analytics & Diagnostics
- Recommend: **uncheck all** for privacy
- Your friend doesn't need to share data with HA project
- Click **Next**

### Screen 4 — Devices Discovered
- HA may auto-discover devices on the network
- Skip for now — click **Finish**
- You can add integrations properly later

---

## 2.3 — Essential HA Settings (Do These First)

### Enable Advanced Mode
This unlocks full add-on configuration options.

1. Click profile icon (bottom left — your initials)
2. Scroll to **Advanced Mode**
3. Toggle **ON**
4. Click **Save**

---

### Disable Auto-Updates
**Critical** — prevents HA from updating itself and breaking version matching with CN add-on.

1. **Settings → System → Updates**
2. Set **"Automatically update Home Assistant"** → **OFF**
3. Set **"Automatically update add-ons"** → **OFF**
4. Click **Save**

> 💡 You control updates quarterly via the update.sh script.
> Auto-updates would break the CN version matching strategy.

---

### Note Your Exact HA Version
1. **Settings → About** (bottom of Settings menu)
2. Note the exact version: e.g., `2025.1.4`
3. Write it down — CN Add-on version must match major.minor

---

### Set the Instance Name
1. **Settings → System → General**
2. **Location name:** `Connect Nest`
   (This appears in some HA internal logs — won't be visible to friends
   but keeps things consistent)
3. **Unit system:** Metric or Imperial based on friend's location
4. **Currency:** Set appropriately
5. Click **Save**

---

### Configure HA Networking (Optional but Recommended)
1. **Settings → System → Network**
2. **Home Assistant URL:** Set to `http://192.168.1.XXX:8123`
   (use your static IP — prevents HA getting confused about its own address)
3. Click **Save**

---

## 2.4 — Disable Nabu Casa / HA Cloud

Nabu Casa (HA Cloud) would expose "Home Assistant" branding in the app.
Make sure it's not enabled:

1. **Settings → Home Assistant Cloud**
2. Ensure it shows **"Sign in"** (not signed in)
3. Do NOT sign in to Nabu Casa — this would reveal HA branding

> Remote access to your friends' systems can be done via **Tailscale**
> (a zero-config VPN) instead — no HA Cloud needed.

---

## 2.5 — Verify HA is Healthy

### Check Supervisor Health
```bash
# SSH into the VM
ssh knadmin@192.168.1.XXX

# Check supervisor status
sudo ha supervisor info
# Look for: "healthy: true"

# Check all running containers
sudo docker ps
# Should show: homeassistant, hassio_supervisor, hassio_dns, hassio_audio, hassio_multicast
```

Expected output:
```
CONTAINER ID   IMAGE                               STATUS
xxxxxxxxxxxx   ghcr.io/home-assistant/...          Up X hours
xxxxxxxxxxxx   ghcr.io/home-assistant/amd64-...   Up X hours
```

### Check HA Logs
```bash
sudo ha core logs --follow
# Press Ctrl+C to stop
# Look for errors in red — there should be none at this stage
```

### Fix Common "Unhealthy" Warning
HA Supervised sometimes flags itself as "unhealthy" in VMware due to AppArmor:

```bash
# Check if AppArmor is the issue
sudo ha supervisor health

# If AppArmor-related:
sudo aa-status
sudo systemctl restart apparmor
sudo ha supervisor repair
```

---

## 2.6 — Install Basic HA Integrations

Before adding MQTT/Zigbee, set up these essentials:

### Time & Date
Should be auto-set from your location. Verify:
1. **Settings → System → General**
2. Check timezone is correct

### Person / User Setup
1. **Settings → People → Add Person**
2. Add yourself (the admin) and optionally the friend
3. This is used for presence detection automations later

---

## 2.7 — Take a Snapshot

In the HA UI:
1. **Settings → System → Backups**
2. Click **"Create backup"**
3. Name: `01-barebone-ha-clean`
4. Type: **Full backup**
5. Click **Create**

This backup is stored inside HA. Also take a VMware snapshot:

```
VMware → Right-click VM → Snapshot → Take Snapshot
Name: 01-barebone-ha-working
Description: HA installed, onboarding complete, no add-ons yet
```

---

## 2.8 — Verify Checklist Before Moving On

```
PART 2 CHECKLIST
================
[ ] HA onboarding completed (account created)
[ ] Advanced Mode enabled
[ ] Auto-updates disabled (HA + add-ons)
[ ] HA version noted: 2025.X.X
[ ] Instance name set to "Connect Nest"
[ ] Nabu Casa NOT signed in
[ ] HA Supervisor shows healthy: true
[ ] No red errors in HA logs
[ ] HA backup created: 01-barebone-ha-clean
[ ] VMware snapshot taken: 01-barebone-ha-working
```

If all boxes are checked — **you have a solid, stable HA base.**
Everything from here builds on top of this stable foundation.

---

## ✅ Part 2 Complete

**→ Next: [PART-3-MQTT.md](PART-3-MQTT.md)**
