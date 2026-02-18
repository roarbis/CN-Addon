# Things You Might Have Missed

> Important considerations not covered in the step-by-step guides.
> Read this before your first friend's installation.

---

## 🔐 Security

### 1. HA is Exposed on the Local Network — Unencrypted
Port 7080 and 8123 serve HTTP (not HTTPS). Anyone on the same WiFi can:
- See traffic between iPhone and HA (unlikely but possible)
- Access the login page directly

**Fix for later:** Set up a self-signed cert or Let's Encrypt.
Not urgent for home LAN, but worth doing if the router has guest WiFi.

### 2. Zigbee2MQTT Web UI Has No Password by Default
Port 8080 is wide open on the LAN. Any device on the network can access it.

**Fix:**
```yaml
# In Zigbee2MQTT config
frontend:
  auth_token: "your_secret_token_here"
```

### 3. HA Long-Lived Access Tokens
If you create API tokens for integrations, treat them like passwords.
They give full HA access. Store them in a password manager.

### 4. HA Account Password Complexity
Enforce a strong password during onboarding. HA has no lockout policy by
default — brute force is possible if the port is ever exposed to the internet.

---

## 🌐 Remote Access (When Friend is Away from Home)

The current setup only works on the **home WiFi network**.
Your friend cannot control their home when away unless you set up remote access.

**Options (easiest to hardest):**

| Option | Cost | Complexity | Notes |
|---|---|---|---|
| **Tailscale** | Free | ⭐ Very easy | VPN mesh, zero config, works everywhere. Recommended. |
| **Cloudflare Tunnel** | Free | ⭐⭐ Easy | Exposes HA via a subdomain, no open ports |
| **Wireguard VPN** | Free | ⭐⭐⭐ Medium | Self-hosted VPN on router |
| **Nabu Casa** | $7/mo | ⭐ Easy | **Avoid** — exposes HA branding |
| **Port forward** | Free | ⭐⭐ Easy | Opens router to internet — security risk |

**Tailscale is the recommendation:**
```bash
# On the Ubuntu VM
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Friend installs Tailscale on iPhone
# Both join the same Tailscale network
# Friend can now access HA from anywhere via Tailscale IP
```

---

## 💾 Backups

### HA Backups (Built-in)
HA backs up its own config. But it doesn't back up the VM itself.

**Set up automatic HA backups:**
1. **Settings → System → Backups → Automatic Backups**
2. Schedule: **Weekly**
3. Copies to keep: **3**

**Copy backups off the VM:**
HA backups are stored inside the VM at `/config/backups/`.
They're useless if the VM's disk dies.

```bash
# On your admin machine — copy latest HA backup locally
scp knadmin@192.168.1.XXX:/config/backups/*.tar \
    "C:\Backups\KonnectNest\"

# Or automate with a weekly script
```

### VMware Snapshots vs Backups
Snapshots = fast undo (stored on same disk — not a real backup)
Backups = exported VM file (stored separately — real backup)

**Export VM backup monthly:**
- VMware → File → Export to OVF
- Saves to external drive or network location
- Can be fully restored if the VM's disk fails

---

## 🔄 What Happens When Windows Restarts

The startup sequence matters:
```
Windows boots
  → VMware starts (Task Scheduler — configured in Part 1)
    → Ubuntu VM starts (30-second delay)
      → Docker starts (systemd service)
        → HA Supervisor starts
          → HA Core starts (~2 minutes)
            → MQTT Broker starts
              → Zigbee2MQTT starts
                → KN Add-on starts
                  → Friend's iPhone PWA reconnects (~30 seconds)
```

**Total time from Windows boot to usable KN:** ~5 minutes.

**Tip:** Set the VMware startup delay to 30 seconds so Windows has time
to fully boot before the VM starts consuming resources.

---

## 📱 Multiple Friend Installs — Keeping Track

When you manage 3+ friends' systems, you need a tracking system.

**Suggested record for each friend:**

```
Friend: [Name]
Install date: 2025-01-XX
Location: [Suburb]

VM Details:
  Host machine: [Make/Model, e.g., HP EliteDesk]
  Host OS: Windows 11 Pro
  Host RAM: 16GB
  VM RAM: 8GB
  VM IP: 192.168.1.XX (static)
  VM SSH: knadmin@192.168.1.XX
  VM Password: [stored in your password manager]

HA Details:
  Version: 2025.1.4
  Admin user: admin
  Admin password: [stored in password manager]
  URL: http://192.168.1.XX:8123 (admin)
  URL: http://192.168.1.XX:7080 (friend's access)

MQTT:
  Password: [stored in password manager]

Zigbee:
  Dongle: SONOFF Zigbee 3.0 Plus
  Dongle port: /dev/serial/by-id/usb-ITead...
  Devices paired: 12

KN Add-on:
  Version: 2025.1.0
  Last updated: 2025-01-XX

iPhone:
  Friend's device: iPhone 15 Pro
  Partner's device: iPhone 13
  Push notifications: working

Notes:
  - Router is TP-Link Archer AX50, DHCP reserved for VM MAC
  - Zigbee channel changed to 25 (WiFi interference on 11)
  - 2 rooms have no Zigbee coverage — repeater needed
```

---

## ⚡ Performance Tuning

### If HA Feels Slow on the VM

**Check VM resource usage:**
```bash
# On Ubuntu VM
htop  # interactive process viewer
# Press F10 to quit

# Check HA-specific resource usage
sudo docker stats --no-stream
```

**Common fixes:**

| Issue | Fix |
|---|---|
| High RAM usage | Increase VM RAM to 8GB |
| Slow automations | Check HA recorder settings (reduce history retention) |
| Zigbee delays | Move USB dongle to a USB extension cable (further from PC interference) |
| Slow dashboard | Reduce number of entities shown on default dashboard |

### HA Recorder — Reduce Database Size
HA logs ALL entity state changes. This can balloon to GBs over time.

```yaml
# In HA configuration.yaml
recorder:
  purge_keep_days: 30     # Only keep 30 days of history (default: 10)
  commit_interval: 30     # Write to DB every 30s (reduces I/O)
  exclude:
    domains:
      - automation
      - script
    entity_globs:
      - sensor.*_rssi     # Exclude signal strength (noisy, not useful)
      - sensor.*_lqi      # Exclude Zigbee link quality
```

---

## 🔌 Devices You Should Set Up Early

Things your friend will likely ask for that take planning:

### Presence Detection (Who's Home)
Works via iPhone + Companion App location, or WiFi device tracking.

```yaml
# Simple WiFi-based presence (in configuration.yaml)
device_tracker:
  - platform: router
    # Requires router integration (Unifi, TP-Link, etc.)
```

### Energy Monitoring
If friend has smart plugs with power monitoring (e.g., SONOFF S31):
- Install **Energy Dashboard** in HA
- **Settings → Energy → Configure**
- Gives real-time and historical power usage

### Lovelace Dashboard Customisation
The default HA dashboard is auto-generated and ugly.
Set up a proper dashboard after all devices are paired.

```yaml
# Recommended cards to install via HACS:
# - mushroom (beautiful minimal cards)
# - mini-graph-card (nice graphs)
# - button-card (fully customisable buttons)
```

> **HACS (Home Assistant Community Store):**
> The HA app store for custom integrations and UI components.
> Install it via: https://hacs.xyz/docs/use/download/download/

---

## 🗓️ Quarterly Maintenance Checklist

```
Every 3 months:
  [ ] Check HA release notes for the new version
  [ ] Test update on YOUR own HA instance first
  [ ] Update friends' HA one at a time (not all at once)
  [ ] Update KN Add-on to matching version
  [ ] Push updated KN Add-on to GitHub
  [ ] Verify all devices still working after update
  [ ] Check Zigbee2MQTT has no unsupported device warnings
  [ ] Verify MQTT broker logs (no unusual errors)
  [ ] Check VM disk usage (should be well under 60GB)
  [ ] Copy HA backup to your admin machine
  [ ] Update your tracking record with new versions

Security:
  [ ] Rotate MQTT passwords (optional but good practice)
  [ ] Check HA for security notifications
  [ ] Verify no unknown HA user accounts exist
```

---

## 🆘 Emergency Recovery

If everything breaks:

### Level 1 — Restart the Add-on
HA → Settings → Add-ons → Konnect Nest → Restart

### Level 2 — Restart HA
```bash
ssh knadmin@192.168.1.XXX
sudo ha core restart
```

### Level 3 — Restart Supervisor
```bash
sudo systemctl restart hassio-supervisor
```

### Level 4 — Revert to VMware Snapshot
VMware → Right-click VM → Snapshot Manager → Select last good snapshot → Restore

### Level 5 — Restore HA Backup
HA → Settings → Backups → select backup → Restore
(Restores HA config, add-on configs, automations — not the VM itself)

### Level 6 — Rebuild from Scratch
Use MASTER-GUIDE.md and start from Part 1.
HA config backup restores everything after fresh install.
Full rebuild takes ~90 minutes.
