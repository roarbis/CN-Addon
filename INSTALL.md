# Konnect Nest — Complete Installation Guide

> From a blank VirtualBox VM to a fully branded Konnect Nest smart home.
> Estimated total time: **45–60 minutes** (mostly waiting for downloads)

---

## Overview — What You're Building

```
VirtualBox VM (Ubuntu 22.04)
  └── Home Assistant Supervised (Docker-based)
        └── Konnect Nest Add-on (nginx branding layer)
              └── iPhone PWA — "Konnect Nest" on home screen
```

---

## PART 1 — VirtualBox VM Setup

> Do this on your admin machine. Takes about 10 minutes.

### 1.1 — Download Ubuntu 22.04 Server ISO

Download from: https://releases.ubuntu.com/22.04/
File: `ubuntu-22.04.x-live-server-amd64.iso`

> **Why Ubuntu 22.04?** It's the officially supported OS for
> Home Assistant Supervised. Other versions work but may need tweaks.

---

### 1.2 — Create the VirtualBox VM

Open VirtualBox → **New**

| Setting | Value |
|---|---|
| Name | `KonnectNest` |
| Type | Linux |
| Version | Ubuntu (64-bit) |
| RAM | **4096 MB minimum** (8192 MB recommended) |
| CPU | 2 cores minimum (4 recommended) |
| Storage | **32 GB minimum** (dynamic VDI) |

**Network — CRITICAL:**
- Go to VM Settings → **Network**
- Adapter 1: Change from **NAT** to **Bridged Adapter**
- Select your host machine's WiFi or Ethernet adapter
- This gives the VM its own IP on your network
- Without this, you cannot reach HA from your phone

---

### 1.3 — Install Ubuntu 22.04

1. Start the VM, select the Ubuntu ISO
2. Choose **"Ubuntu Server"** (minimal install)
3. Network: let it use DHCP for now (we set static IP in bootstrap)
4. Storage: use entire disk, no LVM needed
5. Profile setup:
   - Your name: `Konnect Nest Admin`
   - Server name: `konnectnest`
   - Username: `knadmin` (or whatever you prefer)
   - Password: something strong — **write it down**
6. **Do NOT install** OpenSSH during Ubuntu setup — bootstrap handles it
7. Wait for install to complete → **Reboot**

---

### 1.4 — Note the VM's IP Address

After reboot, Ubuntu shows the IP at the login prompt:
```
konnectnest login: _

  System information:
    ...
    IPv4 address for enp0s3: 192.168.1.XXX   ← NOTE THIS
```

Or after logging in:
```bash
hostname -I
# → 192.168.1.XXX
```

Write this IP down — you'll need it throughout setup.

---

## PART 2 — Bootstrap Script

> This installs Docker, HA OS Agent, and Home Assistant Supervised.
> Run from your **admin machine** (Windows/Mac) via SSH.

### 2.1 — Copy bootstrap.sh to the VM

**From your Windows admin machine** (using Git Bash or WSL):
```bash
scp "C:/Temp/ClaudeCode/HA-KN-Fork/KN-Addon/bootstrap.sh" \
    knadmin@192.168.1.XXX:~/bootstrap.sh
```

Or from the VM itself (if you have internet):
```bash
# On the VM
curl -o ~/bootstrap.sh \
  https://raw.githubusercontent.com/roarbis/KN-Addon/main/bootstrap.sh
```

---

### 2.2 — Configure bootstrap.sh (Optional but Recommended)

Before running, set a **static IP** so the VM always has the same address.
SSH into the VM and edit:

```bash
ssh knadmin@192.168.1.XXX
nano ~/bootstrap.sh
```

Find these lines near the top and fill them in:
```bash
STATIC_IP="192.168.1.100"    # Pick a free IP on your network
GATEWAY="192.168.1.1"         # Your router's IP (usually .1 or .254)
DNS="8.8.8.8,8.8.4.4"        # Leave as Google DNS or use router IP
```

> **How to pick a static IP:**
> - Check your router's DHCP range (usually .100–.200)
> - Pick something outside that range, e.g., `.50` or `.250`
> - Or reserve the current DHCP-assigned IP in your router settings

---

### 2.3 — Run bootstrap.sh

```bash
# On the VM (SSH session)
chmod +x ~/bootstrap.sh
sudo ~/bootstrap.sh
```

**What you'll see:**
```
══════════════════════════════════════════
  Step 1/9 — Checking OS compatibility
══════════════════════════════════════════
[KN] Detected OS: ubuntu 22.04
[KN] ✓ Ubuntu 22.04 LTS — fully supported

══════════════════════════════════════════
  Step 2/9 — Setting hostname
══════════════════════════════════════════
[KN] ✓ Hostname set to: konnectnest

... (continues through all 9 steps) ...

══════════════════════════════════════════
  Konnect Nest VM Ready!
══════════════════════════════════════════
Web (IP):    http://192.168.1.100:8123
Web (mDNS):  http://konnectnest.local:8123
```

> **Total time:** 10–20 minutes depending on internet speed.
> HA pulls ~1GB of Docker images on first start.

---

### 2.4 — Wait for HA to Start

HA takes **3–10 minutes** on first boot (downloading all its containers).

You can watch progress:
```bash
# On the VM
sudo journalctl -fu hassio-supervisor
# Watch for: "INFO (MainThread) [supervisor.api] Starting API"
```

Or just wait and keep refreshing `http://192.168.1.100:8123` in your browser.

---

## PART 3 — Home Assistant Onboarding

> Do this in a browser on your admin machine.
> Takes about 5 minutes.

### 3.1 — Open HA in Browser

Navigate to: `http://192.168.1.XXX:8123`

> **Note:** At this stage you'll see "Home Assistant" branding.
> This is the one-time setup wizard. Once Konnect Nest add-on
> is installed, all branding changes.

---

### 3.2 — Complete the Onboarding Wizard

**Screen 1 — Create Account:**
| Field | Value |
|---|---|
| Name | Your admin name |
| Username | `admin` (or your choice) |
| Password | Strong password — **write it down** |

Click **Create Account**

---

**Screen 2 — Home Location:**
- Set your city/location
- This is used for sunrise/sunset automations
- Click **Next**

---

**Screen 3 — Analytics:**
- Select your preference (analytics are sent to HA project)
- Recommend: **uncheck all** for privacy
- Click **Next**

---

**Screen 4 — Finish:**
- Click **Finish**
- You're now in the HA dashboard

---

### 3.3 — Enable Advanced Mode (Important)

This unlocks add-on configuration options.

1. Click your **username** (bottom left)
2. Scroll down to **Advanced Mode**
3. Toggle it **ON**

---

## PART 4 — Install Konnect Nest Add-on

> This is where the magic happens. Takes about 5 minutes.

### 4.1 — Add the Konnect Nest Repository

1. In HA, go to: **Settings → Add-ons**
2. Click **Add-on Store** (bottom right)
3. Click the **⋮ menu** (top right, three dots)
4. Click **Repositories**
5. In the text field, paste:
   ```
   https://github.com/roarbis/KN-Addon
   ```
6. Click **Add**
7. Click **Close**

> The page will refresh and you'll see a new section
> **"Konnect Nest Add-ons"** in the store.

---

### 4.2 — Install the Add-on

1. In the store, find **"Konnect Nest"**
2. Click on it
3. Click **Install**
4. Wait for the build to complete (2–5 minutes — it's building the Docker container)
5. You'll see a progress log — this is normal

---

### 4.3 — Configure the Add-on

1. Click the **Configuration** tab
2. Verify settings:
   ```yaml
   ha_port: 8123    # Port HA is running on (leave as-is)
   ssl: false       # Set to true if you set up SSL certs
   ```
3. Click **Save**

---

### 4.4 — Start the Add-on

1. Click the **Info** tab
2. Toggle **Start on boot** → ON
3. Toggle **Watchdog** → ON
4. Click **Start**
5. Click **Log** tab to see startup output:
   ```
   [Konnect Nest] ============================================
   [Konnect Nest]   Konnect Nest v2025.1.0
   [Konnect Nest]   Your smart home, beautifully connected.
   [Konnect Nest] ============================================
   [Konnect Nest] HA Core version detected: 2025.1.x
   [Konnect Nest] ✓ HA Core is ready
   [Konnect Nest] ✓ Konnect Nest is running!
   ```

---

### 4.5 — Verify Branding

Refresh your browser. You should now see:
- ✅ Browser tab says **"Konnect Nest"**
- ✅ Sidebar shows the Konnect Nest panel
- ✅ No mention of "Home Assistant" in the UI

If you still see "Home Assistant" — **clear your browser cache**:
- Chrome: `Ctrl+Shift+Delete` → Cached images and files → Clear
- Firefox: `Ctrl+Shift+Delete` → Cache → Clear

---

## PART 5 — iPhone PWA Setup

> Do this on your friend's iPhone. Takes 2 minutes.
> Gives them a "Konnect Nest" icon on their home screen.

### 5.1 — Connect iPhone to Same Network

The iPhone must be on the **same WiFi** as the VM.

---

### 5.2 — Open Safari

> ⚠️ Must be **Safari** — Chrome and other iOS browsers cannot install PWAs.

Navigate to: `http://192.168.1.XXX:7080`

> Port 7080 is the direct access port served by Konnect Nest add-on.
> (Port 8123 still works but shows stock HA login branding)

---

### 5.3 — Add to Home Screen

1. Tap the **Share button** (box with upward arrow ↑) at the bottom
2. Scroll down in the share sheet
3. Tap **"Add to Home Screen"**
4. Name shows: **"Konnect Nest"** ← your brand!
5. Tap **"Add"** (top right)

**Result:** The Konnect Nest icon appears on the iPhone home screen.

---

### 5.4 — Launch the PWA

Tap the **Konnect Nest** icon.

- Opens full-screen (no Safari address bar)
- Shows the Konnect Nest branded interface
- Logs in with the HA account you created
- Behaves like a native app

---

### 5.5 — Enable Push Notifications

1. First time the PWA opens, Safari asks:
   **"konnectnest.local would like to send notifications"**
2. Tap **"Allow"**
3. In HA: Settings → Integrations → you'll see the device registered
4. Notifications from automations now appear as **"Konnect Nest"** on the phone

---

## PART 6 — Final Verification Checklist

Run through this before handing off to your friend:

```
INSTALLATION CHECKLIST
======================
VM Setup
  [ ] VirtualBox VM running Ubuntu 22.04
  [ ] Network: Bridged adapter (not NAT)
  [ ] Static IP configured (optional but recommended)
  [ ] Hostname: konnectnest
  [ ] VM starts automatically when host boots (VirtualBox startup settings)

Home Assistant
  [ ] HA accessible at http://192.168.1.XXX:8123
  [ ] Admin account created
  [ ] Location set
  [ ] Advanced mode enabled

Konnect Nest Add-on
  [ ] KN repository added to HA add-on store
  [ ] Konnect Nest add-on installed
  [ ] Add-on running (green status)
  [ ] Start on boot: ON
  [ ] Watchdog: ON
  [ ] Browser tab shows "Konnect Nest"
  [ ] No "Home Assistant" text visible in UI

iPhone PWA
  [ ] Safari opened (not Chrome)
  [ ] Navigated to http://192.168.1.XXX:7080
  [ ] "Konnect Nest" added to home screen
  [ ] PWA opens full-screen
  [ ] Push notification permission granted

Handoff
  [ ] Friend knows their login credentials
  [ ] Friend knows to use the "Konnect Nest" icon (not Safari/browser)
  [ ] You have SSH access to the VM for future updates
```

---

## PART 7 — VM Auto-Start (Important!)

So Konnect Nest starts automatically when your friend's PC/NUC boots:

**On your admin machine:**
1. Open VirtualBox
2. File → Preferences → General → note the **Default Machine Folder**
3. Create a startup config file, or:

**Easier — VirtualBox CLI:**
```bash
# On Windows admin machine (PowerShell)
# Replace "KonnectNest" with your VM name
VBoxManage modifyvm "KonnectNest" --autostart-enabled on --autostop-type savestate

# On Linux host
echo "KonnectNest" | sudo tee /etc/vbox/autostart.d/konnectnest.conf
```

Or just set the **VM to Headless Start** and add VirtualBox to Windows startup.

---

## PART 8 — Quarterly Update Process

Every quarter (or when you want to update):

### 8.1 — Update Home Assistant
```bash
# In HA UI: Settings → System → Updates
# Or SSH to VM:
ssh knadmin@192.168.1.XXX
sudo ha core update --version 2025.4.0
```

### 8.2 — Update Konnect Nest Add-on
1. Push new version to GitHub (roarbis/KN-Addon)
2. In friend's HA: Settings → Add-ons → Konnect Nest → **Update**

### 8.3 — Version Tracking

| Release | KN Version | HA Version | Date |
|---|---|---|---|
| Initial | 2025.1.0 | 2025.1.x | 2025-01 |
| Q2 | 2025.4.0 | 2025.4.x | 2025-04 |
| Q3 | 2025.7.0 | 2025.7.x | 2025-07 |
| Q4 | 2025.10.0 | 2025.10.x | 2025-10 |

---

## Troubleshooting

### "This site can't be reached" in browser
```bash
# Check HA is running
ssh knadmin@192.168.1.XXX
sudo docker ps | grep homeassistant
# Should show a running container
# If not: sudo systemctl restart hassio-supervisor
```

### "Konnect Nest" add-on won't start
```bash
# Check logs in HA: Settings → Add-ons → Konnect Nest → Log tab
# Common cause: nginx config error or HA not ready yet
# Fix: wait 2 minutes, click Restart in add-on
```

### iPhone shows "Home Assistant" not "Konnect Nest"
- Remove the existing PWA from iPhone home screen
- Clear Safari cache: Settings → Safari → Clear History and Website Data
- Re-add from `http://192.168.1.XXX:7080` (not 8123)

### VM IP Changed (DHCP assigned new IP)
- Set static IP: edit `~/bootstrap.sh`, set `STATIC_IP`, re-run relevant section
- Or reserve the MAC address in your router's DHCP settings

### HA Supervised "unhealthy" warning
```bash
# Check what's wrong
sudo ha jobs options --ignore-conditions healthy
# Or fix AppArmor (common VirtualBox issue)
sudo apt install apparmor-utils
sudo aa-complain /usr/bin/docker
```

---

## Quick Reference

| URL | Purpose |
|---|---|
| `http://VM-IP:8123` | HA direct (shows HA branding on login) |
| `http://VM-IP:7080` | Konnect Nest branded (use this for PWA) |
| `http://konnectnest.local:7080` | mDNS access (same network only) |

| Credential | Location |
|---|---|
| VM SSH | `knadmin@VM-IP` |
| HA Admin | Set during onboarding |
| HA Add-on Repo | `https://github.com/roarbis/KN-Addon` |
