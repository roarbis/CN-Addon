# Pushing Connect Nest Add-on to GitHub

> One-time setup. After this, updates are just git add/commit/push.

---

## Step 1 — Initialize Git repo locally

Open Git Bash or PowerShell on your Windows machine:

```bash
cd "C:\Temp\ClaudeCode\HA-KN-Fork\CN-Addon"
git init
git add .
git commit -m "Initial Connect Nest add-on release v2025.1.0"
```

---

## Step 2 — Connect to GitHub

```bash
git remote add origin https://github.com/roarbis/CN-Addon.git
git branch -M main
git push -u origin main
```

Enter your GitHub credentials when prompted.
If you use 2FA, use a **Personal Access Token** instead of password:
- GitHub → Settings → Developer settings → Personal access tokens → Generate new token
- Scopes needed: `repo`

---

## Step 3 — Verify on GitHub

Open https://github.com/roarbis/CN-Addon

You should see:
```
CN-Addon/
├── repository.json          ← HA reads this first
├── bootstrap.sh             ← VM setup script
├── INSTALL.md               ← This guide
└── connect-nest/
    ├── config.yaml          ← Add-on definition
    ├── Dockerfile           ← Container build
    ├── run.sh               ← Startup script
    └── rootfs/
        └── usr/share/nginx/cn-override/
            ├── manifest.json
            ├── cn-error.html
            └── static/icons/   ← 17 CN icon files
```

---

## Step 4 — Test the Repository URL in HA

In any HA instance:
1. Settings → Add-ons → Store → ⋮ → Repositories
2. Add: `https://github.com/roarbis/CN-Addon`
3. "Connect Nest" should appear in the store

---

## Releasing a Quarterly Update

When you update the add-on (new HA version support, new icons, etc.):

```bash
# 1. Edit version in config.yaml
#    version: "2025.4.0"

# 2. Edit minimum HA version if needed
#    homeassistant: "2025.1.0"

# 3. Commit and push
cd "C:\Temp\ClaudeCode\HA-KN-Fork\CN-Addon"
git add .
git commit -m "KN v2025.4.0 — tested on HA 2025.4.x"
git push

# 4. Create a GitHub Release (optional but nice)
# GitHub → Releases → Draft new release
# Tag: v2025.4.0
# Title: Connect Nest v2025.4.0
# Body: "Tested on Home Assistant 2025.4.x. Quarterly update."
```

Friends will see an **"Update available"** notification in their HA add-on panel automatically.

---

## Repository Structure Explained

| File | What HA Does With It |
|---|---|
| `repository.json` | HA fetches this first to verify it's a valid add-on repo |
| `connect-nest/config.yaml` | HA reads add-on name, version, arch, ports, options |
| `connect-nest/Dockerfile` | HA Supervisor builds this on the friend's machine |
| `connect-nest/run.sh` | Executed when the add-on container starts |
| `connect-nest/rootfs/` | Files copied into the container at build time |
