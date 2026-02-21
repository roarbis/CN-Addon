# PART 5 — Connect Nest Add-on

> **Time:** ~10 minutes
> **Previous step:** Part 4 complete — HA + MQTT + Zigbee2MQTT all working
> **Goal:** Apply Connect Nest branding on top of the working HA install

---

## Why We Do This Last

The CN add-on is the **final layer** — applied after everything else works.
This means:
- If branding breaks something, you roll back just the add-on
- Your MQTT, Zigbee2MQTT, and automations are untouched
- The friend's smart home keeps working even if CN is temporarily disabled

---

## 5.1 — Push CN Add-on to GitHub (Admin — One Time)

> Skip this if already done. Only needed once when first setting up.

On your admin Windows machine:
```bash
cd "C:\Temp\ClaudeCode\HA-KN-Fork\CN-Addon"
git remote add origin https://github.com/roarbis/CN-Addon.git
git branch -M main
git push -u origin main
```

Verify at: https://github.com/roarbis/CN-Addon
You should see all files including `repository.json` in the root.

---

## 5.2 — Add CN Repository to HA

On the friend's HA:

1. **Settings → Add-ons → Add-on Store**
2. Click **⋮ menu** (top right, three dots)
3. Click **Repositories**
4. Paste: `https://github.com/roarbis/CN-Addon`
5. Click **Add**
6. Click **Close**

The page refreshes. Scroll down to find:
**"Connect Nest Add-ons"** section with **"Connect Nest"** listed.

---

## 5.3 — Verify Version Matching

Before installing, confirm versions match:

| Check | Where to find |
|---|---|
| Current HA version | Settings → About (e.g., `2025.1.4`) |
| CN Add-on version | Add-on store listing (e.g., `2025.1.0`) |

> CN `2025.1.x` works with HA `2025.1.x` ✅
> CN `2025.1.x` + HA `2025.4.x` = may work but not tested ⚠️

If versions are mismatched, update the CN add-on first (see PART-7-UPDATES.md).

---

## 5.4 — Install the Connect Nest Add-on

1. Click **"Connect Nest"** in the store
2. Click **Install**
3. Wait 3-5 minutes (building Docker container)
4. You'll see the build log — progress is normal

---

## 5.5 — Configure the Add-on

Click **Configuration** tab:

```yaml
ha_port: 8123     # HA backend port — leave as default
ssl: false        # Set to true only if you've set up SSL certs
certfile: fullchain.pem
keyfile: privkey.pem
```

Click **Save**

---

## 5.6 — Start the Add-on

1. Click **Info** tab
2. **Start on boot** → ON
3. **Watchdog** → ON
4. Click **Start**

Check **Log** tab — you should see:
```
[Connect Nest] ============================================
[Connect Nest]   Connect Nest v2025.1.0
[Connect Nest]   Your smart home, beautifully connected.
[Connect Nest] ============================================
[Connect Nest] HA Core version detected: 2025.1.X
[Connect Nest] ✓ HA Core is ready
[Connect Nest] Starting Connect Nest...
[Connect Nest] ✓ Connect Nest is running!
[Connect Nest]   Direct access: port 7080
```

---

## 5.7 — Verify Branding

### Browser Test:
1. Open: `http://192.168.1.XXX:7080`
2. Browser tab should show: **"Connect Nest"**
3. Login page should show CN logo and colors
4. After login: sidebar, dashboard — no "Home Assistant" text visible

### Manifest Test:
```bash
curl http://192.168.1.XXX:7080/manifest.json
# Should return JSON with "name": "Connect Nest"
```

### Cache Clear (if still seeing HA branding):
- Chrome: `Ctrl+Shift+Delete` → Cached images → Clear data
- Firefox: `Ctrl+Shift+Delete` → Cache → Clear

---

## 5.8 — What Port to Use Going Forward

| Port | Use case |
|---|---|
| `:8123` | Your admin/troubleshooting access (shows HA branding on login) |
| `:7080` | Friend's access — fully branded as Connect Nest |
| `:8080` | Zigbee2MQTT web UI (internal use only — don't share with friends) |

**Tell your friend to always use port 7080.**
Bookmark `http://192.168.1.XXX:7080` for them.

---

## 5.9 — Take a Final Snapshot

```
HA: Settings → Backups → Create backup
Name: 04-connect-nest-branding-active

VMware: Snapshot → Take Snapshot
Name: 04-connect-nest-complete
Description: Full CN stack running — HA + MQTT + Z2M + CN branding
```

---

## ✅ Part 5 Complete

| Check | Status |
|---|---|
| CN repository added to HA add-on store | ☐ |
| CN add-on installed (version matches HA) | ☐ |
| Add-on running (green status) | ☐ |
| Start on boot: ON | ☐ |
| Watchdog: ON | ☐ |
| Browser shows "Connect Nest" at :7080 | ☐ |
| No "Home Assistant" text visible to user | ☐ |
| Final snapshots taken | ☐ |

**→ Next: [PART-6-PWA-IOS.md](PART-6-PWA-IOS.md)**
