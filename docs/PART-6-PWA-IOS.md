# PART 6 — iPhone PWA Setup

> **Time:** ~5 minutes per iPhone
> **Previous step:** Part 5 complete — Connect Nest add-on running on :7080
> **Goal:** "Connect Nest" app icon on friend's iPhone home screen

---

## What Your Friend Will See

After this part, your friend has:
- A **"Connect Nest"** icon on their iPhone home screen
- Opens **full-screen** (no browser address bar — looks like a native app)
- Shows the **KN branded interface** with their smart home devices
- **Push notifications** from automations show as "Connect Nest"
- Login session persists (they stay logged in)

---

## Prerequisites

Before starting:
- ✅ CN add-on running at `http://192.168.1.XXX:7080`
- ✅ iPhone on the **same WiFi** as the VM
- ✅ iPhone running **iOS 16.4 or later** (for push notification support)

---

## 6.1 — Open Safari on iPhone

> ⚠️ **Must be Safari** — Chrome, Firefox and other iOS browsers cannot
> install PWAs. This is an Apple restriction.

1. Open **Safari** (the blue compass icon)
2. Type in the address bar: `http://192.168.1.XXX:7080`
   (replace XXX with the VM's actual IP)
3. You should see the **Connect Nest** login screen
4. **Log in** with the HA admin credentials

---

## 6.2 — Add to Home Screen

1. Tap the **Share button** at the bottom of Safari
   (box with an upward arrow ↑)
2. Scroll down in the Share Sheet
3. Tap **"Add to Home Screen"**

You'll see:
```
┌─────────────────────────────┐
│  Add to Home Screen         │
│                             │
│  [KN Icon]  Connect Nest ←  │  ← Your brand name!
│                             │
│  192.168.1.XXX:7080         │
│                      [Add]  │
└─────────────────────────────┘
```

4. The name already says **"Connect Nest"** (from manifest.json)
5. Tap **"Add"** (top right)

---

## 6.3 — Launch from Home Screen

1. Press the iPhone Home button (or swipe up)
2. Find the **"Connect Nest"** icon on the home screen
3. Tap it

**What you get:**
- Opens **full screen** — no Safari address bar, no browser controls
- Shows in the App Switcher as its own "app"
- The CN logo and colours you designed
- The full smart home interface

---

## 6.4 — Enable Push Notifications

The first time the PWA opens, iOS may show:

```
"connectnest.local" Would Like to
Send You Notifications

[Don't Allow]    [Allow]
```

> Tap **"Allow"**

If the prompt doesn't appear automatically:
1. In the PWA, go to **Settings → Companion App**
   (or **Settings → Mobile App** in HA)
2. Tap **"Register for push notifications"**
3. iOS will prompt for permission — Allow

### Verify Notification Registration:
In HA: **Settings → Devices & Services**
You should see a new device: **"[Friend's Name]'s iPhone"**
or similar. This is the registered PWA device.

---

## 6.5 — Test Push Notification

Send a test notification from HA:

1. **Developer Tools → Services**
2. Service: `notify.mobile_app_[device_name]`
   (the device name shown in Settings → Devices)
3. Service data:
```yaml
title: "Connect Nest"
message: "Your smart home is connected!"
```
4. Click **Call Service**

Your friend's iPhone should receive:
```
┌─────────────────────────────┐
│ [KN Icon]  Connect Nest     │  ← Your brand, your icon
│ Your smart home is          │
│ connected!                  │
└─────────────────────────────┘
```

✅ The notification shows **"Connect Nest"** — not "Home Assistant".

---

## 6.6 — Configure Useful Automations

Now that notifications work, set up automations your friend will love:

### Example 1 — Door Sensor Notification
```yaml
automation:
  alias: "Front Door Opened"
  trigger:
    platform: state
    entity_id: binary_sensor.front_door_contact
    to: "on"
  action:
    service: notify.mobile_app_friends_iphone
    data:
      title: "Front Door"
      message: "Front door was opened"
      data:
        push:
          sound: default
```

### Example 2 — Motion Alert with Time Filter
```yaml
automation:
  alias: "Motion Alert After Dark"
  trigger:
    platform: state
    entity_id: binary_sensor.backyard_motion
    to: "on"
  condition:
    condition: sun
    after: sunset
  action:
    service: notify.mobile_app_friends_iphone
    data:
      title: "Motion Detected"
      message: "Movement in the backyard"
```

### Example 3 — Device Offline Alert
```yaml
automation:
  alias: "Device Offline Alert"
  trigger:
    platform: state
    entity_id: binary_sensor.living_room_sensor
    to: "unavailable"
    for:
      minutes: 10
  action:
    service: notify.mobile_app_friends_iphone
    data:
      title: "Device Offline"
      message: "Living room sensor is not responding"
```

---

## 6.7 — Multiple iPhones / Family Members

If the friend has a partner or family members who also want access:

1. Create additional HA user accounts:
   **Settings → People → Add Person → Add User**

2. Each person installs the PWA on their iPhone separately:
   - Same steps as above (Section 6.1–6.4)
   - Each registers as a separate device in HA
   - Each gets their own notification target (`notify.mobile_app_xxx`)

3. Each person sees the same **"Connect Nest"** branded interface

---

## 6.8 — Troubleshooting PWA

### PWA shows "Home Assistant" instead of "Connect Nest"
**Cause:** Browser cached the old manifest from port 8123.

**Fix:**
1. Remove the existing icon from iPhone home screen
   (Press and hold → Remove → Remove from Home Screen)
2. On iPhone: **Settings → Safari → Clear History and Website Data**
3. Re-add the PWA from `http://192.168.1.XXX:7080` (not 8123!)

### "Add to Home Screen" option not visible in Share Sheet
- Make sure you're in **Safari** (not Chrome or Firefox)
- Scroll **down** in the share sheet — it's not always visible without scrolling
- Try tapping the share sheet heading to expand it

### PWA loses login session
- This happens if Safari clears site data (iOS "Clear History" affects PWAs)
- **Settings → Safari → Advanced → Website Data**
- Find `192.168.1.XXX` → Swipe left → Delete? No — instead:
- **Don't** clear website data if you want to stay logged in

### Push notifications not arriving
1. Check iPhone: **Settings → Notifications → Connect Nest** → ensure All On
2. Check iOS version: must be **16.4+** for Web Push
3. In HA: check the mobile device is still registered (Settings → Devices)
4. Re-register: open PWA → Settings → Companion App → Re-register

### IP address changed (DHCP)
If the VM's IP changed, the PWA won't load.
- Set a static IP (PART-2 step 2.1 in bootstrap script)
- OR reserve the VM's MAC address in the router DHCP settings
- Then re-add PWA with new IP (only takes 2 minutes)

---

## 6.9 — Bookmark for Friend

Create simple instructions to leave with your friend:

```
╔══════════════════════════════════════╗
║        KONNECT NEST                  ║
║        Smart Home Guide              ║
╠══════════════════════════════════════╣
║                                      ║
║  Tap the "Connect Nest" icon         ║
║  on your home screen.                ║
║                                      ║
║  Username: ___________________       ║
║  (Don't share this!)                 ║
║                                      ║
║  If the app isn't working:           ║
║  Make sure your phone is on          ║
║  the home WiFi network.              ║
║                                      ║
║  For help: [your phone number]       ║
╚══════════════════════════════════════╝
```

---

## ✅ Part 6 Complete — Full Stack Running!

| Check | Status |
|---|---|
| PWA installed on iPhone from :7080 | ☐ |
| Home screen shows "Connect Nest" icon | ☐ |
| PWA opens full-screen (no browser bar) | ☐ |
| Push notification permission granted | ☐ |
| Test notification received showing "Connect Nest" | ☐ |
| Device registered in HA (Settings → Devices) | ☐ |
| At least 1 automation set up | ☐ |

---

## 🎉 Installation Complete!

Your friend now has a fully branded **Connect Nest** smart home:

```
✅ Ubuntu 22.04 VM on VMware (auto-starts with Windows)
✅ Home Assistant Supervised (pinned version, auto-updates disabled)
✅ Mosquitto MQTT Broker (device communication backbone)
✅ Zigbee2MQTT (all Zigbee devices paired and working)
✅ Connect Nest Add-on (full branding — no "Home Assistant" visible)
✅ iPhone PWA ("Connect Nest" on home screen, push notifications)
```

**→ Next maintenance: [PART-7-UPDATES.md](PART-7-UPDATES.md)**
