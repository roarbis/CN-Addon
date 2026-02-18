# Konnect Nest — Master Installation Guide
# VMware Workstation Pro Edition

> **Audience:** You (the admin) installing at a friend's place
> **Approach:** Phased — barebone HA first, then services, then branding
> **Total time:** 90–120 minutes (mostly waiting for downloads)

---

## Architecture — What You're Building

```
Friend's Windows Machine
└── VMware Workstation Pro (free)
    └── Ubuntu 22.04 LTS VM  ←─ "konnectnest" hostname
        └── Home Assistant Supervised (Docker)
            ├── Core HA          :8123  ← automation engine
            ├── Mosquitto MQTT   :1883  ← message broker for devices
            ├── Zigbee2MQTT      :8080  ← Zigbee USB dongle bridge
            └── Konnect Nest     :7080  ← branded nginx overlay
                └── iPhone PWA          ← "Konnect Nest" on home screen
```

---

## Phase Overview

| Phase | What | Time | Guide |
|---|---|---|---|
| **1** | VMware VM + Ubuntu | 20 min | [PART-1-VMWARE-VM.md](PART-1-VMWARE-VM.md) |
| **2** | HA Barebone (stable, tested) | 20 min | [PART-2-HA-INSTALL.md](PART-2-HA-INSTALL.md) |
| **3** | MQTT Broker | 5 min | [PART-3-MQTT.md](PART-3-MQTT.md) |
| **4** | Zigbee2MQTT | 10 min | [PART-4-ZIGBEE2MQTT.md](PART-4-ZIGBEE2MQTT.md) |
| **5** | Konnect Nest Add-on | 10 min | [PART-5-KN-ADDON.md](PART-5-KN-ADDON.md) |
| **6** | iPhone PWA | 5 min | [PART-6-PWA-IOS.md](PART-6-PWA-IOS.md) |

---

## ⚠️ Things You Must NOT Miss

> Read this before starting. These are the most common failure points.

### Networking
- ✅ VMware network adapter MUST be **Bridged** (not NAT)
- ✅ Set a **static IP** on the Ubuntu VM before installing HA
- ✅ Router should ideally **reserve** the VM's MAC address → static DHCP lease
- ✅ iPhone must be on the **same WiFi** as the VM for PWA to work

### USB (Zigbee dongle)
- ✅ Plug Zigbee USB dongle into Windows HOST **before** starting VMware
- ✅ In VMware: VM menu → Removable Devices → [dongle] → Connect
- ✅ The dongle disappears from Windows and appears in the Ubuntu VM
- ✅ Always connect dongle BEFORE starting HA

### HA Version Pinning
- ✅ Note the exact HA version installed (shown in HA → Settings → About)
- ✅ KN Add-on version must match (KN 2025.1.x = HA 2025.1.x)
- ✅ Do NOT let HA auto-update — disable auto-updates in HA settings

### Credentials — Write These Down
```
VMware VM SSH:    knadmin @ [VM static IP]   Password: [set during install]
HA Admin:         admin                       Password: [set during onboarding]
MQTT:             mqtt_user                   Password: [set during MQTT setup]
Zigbee2MQTT:      (no auth by default on LAN)
```

---

## Quick Reference — Ports

| Service | Port | URL |
|---|---|---|
| Home Assistant | 8123 | http://[VM-IP]:8123 |
| Konnect Nest (branded) | 7080 | http://[VM-IP]:7080 |
| MQTT Broker | 1883 | mqtt://[VM-IP]:1883 |
| Zigbee2MQTT UI | 8080 | http://[VM-IP]:8080 |
| SSH (VM) | 22 | ssh knadmin@[VM-IP] |

---

## What's NOT in This Guide (Future Phases)

- HTTPS / SSL certificates (Let's Encrypt)
- External access / VPN (Tailscale recommended)
- iOS native app (TestFlight — separate project)
- Z-Wave devices (similar to Zigbee, separate add-on)
- HA Cloud / Nabu Casa (deliberately avoided — exposes HA branding)
