# PART 1 — VMware Workstation Pro + Ubuntu 22.04 VM

> **Time:** ~20 minutes
> **You need:** Windows machine, internet connection, USB drive (optional)
> **Previous step:** None — this is the starting point

---

## 1.1 — Install VMware Workstation Pro

### Download
1. Go to: https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion
2. Click **"Download for Free"**
3. Create / log into a **Broadcom account** (required since 2024 acquisition)
4. Navigate: My Downloads → VMware Workstation Pro → **17.x for Windows**
5. Download the `.exe` installer (~600MB)

### Install
1. Right-click installer → **"Run as administrator"**
2. Accept license agreement
3. Setup type: **Typical** → Next
4. Uncheck "Help improve VMware" if preferred → Next
5. Shortcuts: leave defaults → Next
6. License: select **"Use VMware Workstation 17 for Personal Use"** (free tier)
7. Click **Install** (takes ~3 minutes)
8. Click **Finish**
9. **Restart Windows** when prompted

---

## 1.2 — Download Ubuntu 22.04 Server ISO

> Ubuntu 22.04 LTS is the officially supported OS for HA Supervised.

Download: https://releases.ubuntu.com/22.04/
File: `ubuntu-22.04.x-live-server-amd64.iso` (~1.4GB)

Save to somewhere easy to find, e.g., `C:\ISOs\`

---

## 1.3 — Create the VMware VM

Open **VMware Workstation Pro** → **Create a New Virtual Machine**

### Step 1 — Setup Type
Select **"Typical (recommended)"** → **Next**

### Step 2 — Guest OS Installation
- Select **"Installer disc image file (ISO)"**
- Click **Browse** → find your Ubuntu ISO
- VMware will detect it as Ubuntu 64-bit automatically
- Click **Next**

### Step 3 — Easy Install (VMware feature — SKIP IT)
VMware offers "Easy Install" for Ubuntu — **do NOT use it**.
It installs a desktop version with wrong settings.

- Leave name/password fields **blank**
- Click **Next**

### Step 4 — VM Name & Location
| Field | Value |
|---|---|
| Virtual machine name | `ConnectNest` |
| Location | `C:\VMs\ConnectNest` (or your preferred path) |

Click **Next**

### Step 5 — Disk Capacity
| Setting | Value |
|---|---|
| Maximum disk size | **60 GB** (gives plenty of room for HA data + add-ons) |
| Disk type | **"Store virtual disk as a single file"** |

Click **Next**

### Step 6 — Customize Hardware (IMPORTANT)
Click **"Customize Hardware..."** before finishing.

| Hardware | Setting |
|---|---|
| **Memory** | **4096 MB** minimum — set to 8192 if host has 16GB+ RAM |
| **Processors** | **2** cores (4 if host has 8+ cores) |
| **Network Adapter** | Change to **Bridged: Connected directly to physical network** |
| **USB Controller** | Ensure **USB 3.1** is selected |
| **Sound Card** | Remove it (not needed, saves resources) |
| **Printer** | Remove it (not needed) |

> ⚠️ **Network Adapter MUST be Bridged** — this is the most common mistake.
> Bridged mode gives the VM its own IP on your network.
> NAT mode hides it behind the host and breaks iPhone PWA access.

Click **Close** → **Finish**

---

## 1.4 — Configure VMware for Performance

Before starting the VM, right-click it → **Settings**

### Processors
- Number of processor cores: **2** (or 4)
- ✅ Check **"Virtualize Intel VT-x/EPT or AMD-V/RVI"**
  (enables nested virtualization — needed for some HA features)

### Advanced
- Firmware type: **UEFI** (better than BIOS for Ubuntu 22.04)
- ✅ **"Disable side channel mitigations"** — improves VM performance

Click **OK**

---

## 1.5 — Install Ubuntu 22.04 Server

Start the VM (green Play button).

### Boot Menu
- Ubuntu installer starts automatically
- If asked for boot device, select the ISO/DVD

### Ubuntu Server Installation Wizard

**Welcome screen:**
Select your language → **English** → Enter

**Keyboard configuration:**
- Layout: match your keyboard → **Done**

**Choose type of install:**
- Select **"Ubuntu Server"** (NOT minimized)
- → **Done**

**Network connections:**
- You'll see your network interface (e.g., `ens33`)
- It shows a DHCP-assigned IP like `192.168.1.XXX`
- Leave as DHCP for now — **we set static IP in the bootstrap script**
- → **Done**

**Configure proxy:**
- Leave blank → **Done**

**Configure Ubuntu archive mirror:**
- Leave default → **Done** (or wait for it to test the mirror)

**Storage configuration:**
- Select **"Use an entire disk"**
- Select the 60GB disk → **Done**
- Storage summary → **Done**
- Confirm destructive action → **Continue**

**Profile setup — CRITICAL:**
| Field | Value |
|---|---|
| Your name | `KN Admin` |
| Your server's name | `connectnest` |
| Pick a username | `knadmin` |
| Choose a password | Something strong — **write it down** |
| Confirm password | Same |

→ **Done**

**Upgrade to Ubuntu Pro:**
- Select **"Skip for now"** → **Continue**

**SSH Setup:**
- ✅ **Check "Install OpenSSH server"** — this is essential for remote management
- Import SSH identity: **No** (unless you have GitHub SSH keys)
- → **Done**

**Featured server snaps:**
- Do NOT select anything
- → **Done**

**Installation begins** (~5 minutes)

When complete: **"Reboot Now"**

When prompted **"Remove the installation medium"** → press **Enter**

---

## 1.6 — First Login & Note the IP

The VM reboots and shows a login prompt:

```
connectnest login: knadmin
Password: [your password]
```

After login, get the IP address:
```bash
hostname -I
# Example output: 192.168.1.87
```

**Write this IP down** — you'll use it constantly.

---

## 1.7 — Verify SSH Access from Your Admin Machine

On your Windows machine, open **PowerShell** or **Git Bash**:

```bash
ssh knadmin@192.168.1.87
# Accept fingerprint: yes
# Enter password
```

You should get a shell prompt:
```
knadmin@connectnest:~$
```

✅ SSH working means you can manage this VM remotely for all future steps.

---

## 1.8 — VMware Tools Installation

VMware Tools improves performance and integration. Install it now:

```bash
# On the Ubuntu VM (via SSH or VM console)
sudo apt-get update -qq
sudo apt-get install -y open-vm-tools
sudo systemctl enable open-vm-tools
sudo systemctl start open-vm-tools
```

Verify:
```bash
vmware-toolsd --version
# Should show: VMware Tools daemon, version XX.X.X
```

---

## 1.9 — VMware Auto-Start Setup

So the VM starts automatically when Windows boots (essential for friends' setups):

### Method A — VMware Shared VM Auto-Start (Recommended)
1. In VMware: **Edit → Preferences → Shared VMs**
2. Enable sharing → the VM path is registered

Then use Windows Task Scheduler:
1. Open **Task Scheduler** (search in Start menu)
2. **Create Basic Task**
3. Name: `Start ConnectNest VM`
4. Trigger: **"When the computer starts"**
5. Action: **"Start a program"**
6. Program: `"C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"`
7. Arguments: `start "C:\VMs\ConnectNest\ConnectNest.vmx" nogui`
8. ✅ Check **"Open Properties dialog"** → Finish
9. In Properties → General: ✅ **"Run whether user is logged on or not"**
10. ✅ **"Run with highest privileges"**
11. Click OK → enter Windows admin password

### Method B — Startup Folder (Simpler but only runs when user logs in)
```powershell
# Run in PowerShell
$startup = [Environment]::GetFolderPath("Startup")
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$startup\ConnectNest.lnk")
$sc.TargetPath = "C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe"
$sc.Arguments = 'start "C:\VMs\ConnectNest\ConnectNest.vmx" nogui'
$sc.Save()
Write-Host "Startup shortcut created"
```

---

## 1.10 — Take a VMware Snapshot

Before doing anything else — take a clean snapshot.
This is your **"factory reset"** point if anything goes wrong.

In VMware:
- Right-click `ConnectNest` VM → **Snapshot → Take Snapshot**
- Name: `00-clean-ubuntu-install`
- Description: `Fresh Ubuntu 22.04, SSH only, no HA yet`
- Click **Take Snapshot**

> 💡 **Snapshot strategy throughout this guide:**
> Take a snapshot after each phase completes successfully.
> If a later phase breaks something, you can roll back to the last good snapshot.

---

## ✅ Part 1 Complete

| Check | Status |
|---|---|
| VMware Workstation Pro installed | ☐ |
| Ubuntu 22.04 VM created (60GB, 4GB RAM, Bridged network) | ☐ |
| Ubuntu installed, SSH working | ☐ |
| VMware Tools installed | ☐ |
| VM IP noted: `192.168.1.____` | ☐ |
| Auto-start configured | ☐ |
| Snapshot `00-clean-ubuntu-install` taken | ☐ |

**→ Next: [PART-2-HA-INSTALL.md](PART-2-HA-INSTALL.md)**
