#!/usr/bin/env bash
# ============================================================
#  Konnect Nest — VMware Ubuntu VM Bootstrap Script
#  Phase 1: Installs prerequisites + HA Supervised
#
#  Run this ONCE on a fresh Ubuntu 22.04 VM after SSH access
#  is confirmed. Does NOT install MQTT or Zigbee2MQTT —
#  those are installed separately via HA add-ons.
#
#  Usage:
#    sudo ./bootstrap-vmware.sh
#
#  Or run directly from GitHub (after pushing):
#    curl -sSL https://raw.githubusercontent.com/roarbis/KN-Addon/main/scripts/bootstrap-vmware.sh | sudo bash
#
#  What this installs:
#    - System prerequisites (AppArmor, avahi, NetworkManager, etc.)
#    - Docker Engine (CE)
#    - HA OS Agent
#    - Home Assistant Supervised
#
#  What this does NOT install (you control these separately):
#    - Static IP (prompted interactively — your choice)
#    - MQTT Broker (HA add-on — installed via HA UI)
#    - Zigbee2MQTT (HA add-on — installed via HA UI)
#    - Konnect Nest (HA add-on — installed via HA UI)
# ============================================================

set -euo pipefail

# ── Must run as root ────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo $0"; exit 1; }

# ── Colours ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[KN]${NC} $*"; }
success() { echo -e "${GREEN}[KN] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[KN] ⚠${NC} $*"; }
error()   { echo -e "${RED}[KN] ✗${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $*${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════${NC}\n"; }

# ── Versions ────────────────────────────────────────────────
HAOS_AGENT_VERSION="2.0.0"
# Leave HA_VERSION empty to install latest stable
# Or pin to specific version: HA_VERSION="2025.1.0"
HA_VERSION=""

# ── Banner ──────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Konnect Nest — Bootstrap for VMware     ║"
echo "  ║   Home Assistant Supervised Installer     ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}\n"

# ── Step 1: OS Check ────────────────────────────────────────
header "Step 1/8 — OS Compatibility Check"

OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VER=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
ARCH=$(dpkg --print-architecture)

info "OS: ${OS_ID} ${OS_VER} (${ARCH})"

case "${OS_ID}-${OS_VER}" in
    ubuntu-22.04) success "Ubuntu 22.04 LTS — fully supported" ;;
    ubuntu-24.04) success "Ubuntu 24.04 LTS — supported" ;;
    debian-12)    success "Debian 12 — supported" ;;
    *)
        warn "OS ${OS_ID} ${OS_VER} is not officially tested"
        read -rp "Continue anyway? [y/N]: " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 0
        ;;
esac

# ── Step 2: Hostname ─────────────────────────────────────────
header "Step 2/8 — Hostname Configuration"

CURRENT_HOST=$(hostname)
info "Current hostname: ${CURRENT_HOST}"

if [[ "$CURRENT_HOST" != "konnectnest" ]]; then
    read -rp "Set hostname to 'konnectnest'? [Y/n]: " set_host
    if [[ ! "$set_host" =~ ^[Nn]$ ]]; then
        hostnamectl set-hostname konnectnest
        # Update /etc/hosts safely
        if grep -q "127.0.1.1" /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\tkonnectnest/" /etc/hosts
        else
            echo "127.0.1.1	konnectnest" >> /etc/hosts
        fi
        success "Hostname set to: konnectnest"
        info "mDNS: konnectnest.local (available after services start)"
    fi
else
    success "Hostname already: konnectnest"
fi

# ── Step 3: Static IP (Optional — your choice) ───────────────
header "Step 3/8 — Network / Static IP"

CURRENT_IP=$(hostname -I | awk '{print $1}')
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

info "Current IP (DHCP): ${CURRENT_IP}"
info "Network interface: ${INTERFACE}"
echo ""
warn "A static IP prevents the VM address changing on router restart."
warn "You can also set a DHCP reservation in your router instead."
echo ""
read -rp "Set a static IP now? [y/N]: " set_static

if [[ "$set_static" =~ ^[Yy]$ ]]; then
    read -rp "  Enter static IP (e.g. 192.168.1.50): " STATIC_IP
    read -rp "  Enter gateway   (e.g. 192.168.1.1): " GATEWAY
    read -rp "  Enter DNS       [8.8.8.8]: " DNS_INPUT
    DNS="${DNS_INPUT:-8.8.8.8}"

    # Validate basic IP format
    [[ "$STATIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        error "Invalid IP format: ${STATIC_IP}"
    [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        error "Invalid gateway format: ${GATEWAY}"

    # Use NetworkManager (Ubuntu 22.04 default)
    if command -v nmcli &>/dev/null; then
        CON_NAME=$(nmcli -t -f NAME connection show --active | head -1)
        nmcli connection modify "$CON_NAME" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/24" \
            ipv4.gateway   "$GATEWAY" \
            ipv4.dns       "$DNS"
        nmcli connection up "$CON_NAME" 2>/dev/null || true
        success "Static IP configured: ${STATIC_IP}"
        warn "SSH may briefly disconnect — reconnect to ${STATIC_IP}"
    else
        # Fallback: netplan
        cat > /etc/netplan/99-konnectnest-static.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    ${INTERFACE}:
      addresses:
        - ${STATIC_IP}/24
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS}]
NETPLAN
        chmod 600 /etc/netplan/99-konnectnest-static.yaml
        netplan apply 2>/dev/null || true
        success "Static IP configured via netplan: ${STATIC_IP}"
    fi
    CURRENT_IP="$STATIC_IP"
else
    info "Keeping DHCP. Current IP: ${CURRENT_IP}"
    warn "Recommend: set a DHCP reservation in your router for MAC:"
    ip link show "$INTERFACE" | grep ether | awk '{print "  MAC: "$2}'
fi

# ── Step 4: System Update ────────────────────────────────────
header "Step 4/8 — System Update"
info "Updating package lists..."
apt-get update -qq
info "Upgrading installed packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
success "System up to date"

# ── Step 5: Install Prerequisites ───────────────────────────
header "Step 5/8 — Installing Prerequisites"

info "Installing required packages for HA Supervised..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apparmor \
    bluez \
    cifs-utils \
    curl \
    dbus \
    jq \
    libglib2.0-bin \
    lsb-release \
    network-manager \
    nfs-common \
    systemd-journal-remote \
    udisks2 \
    wget \
    ca-certificates \
    gnupg \
    avahi-daemon \
    avahi-utils \
    open-vm-tools \
    net-tools \
    socat \
    2>&1 | grep -E "(installed|upgraded|already)" || true

# Enable required services
systemctl enable --now avahi-daemon 2>/dev/null || true
systemctl enable --now NetworkManager 2>/dev/null || true

success "Prerequisites installed (including VMware open-vm-tools)"

# ── Step 6: Docker Engine ────────────────────────────────────
header "Step 6/8 — Docker Engine"

if command -v docker &>/dev/null; then
    success "Docker already installed: $(docker --version | awk '{print $3}' | tr -d ',')"
else
    info "Installing Docker Engine..."

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${OS_ID} \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    success "Docker installed: $(docker --version | awk '{print $3}' | tr -d ',')"
fi

# Add knadmin to docker group
usermod -aG docker knadmin 2>/dev/null || true

# ── Step 7: HA OS Agent ──────────────────────────────────────
header "Step 7/8 — Home Assistant OS Agent"

if systemctl is-active --quiet haos-agent 2>/dev/null || \
   gdbus introspect --system --dest io.hass.os \
         --object-path /io/hass/os &>/dev/null 2>&1; then
    success "HA OS Agent already installed"
else
    info "Installing HA OS Agent v${HAOS_AGENT_VERSION}..."

    case "$ARCH" in
        amd64)  HA_ARCH="amd64" ;;
        arm64)  HA_ARCH="aarch64" ;;
        armhf)  HA_ARCH="armv7" ;;
        *)      error "Unsupported arch: ${ARCH}" ;;
    esac

    AGENT_URL="https://github.com/home-assistant/os-agent/releases/download/${HAOS_AGENT_VERSION}/os-agent_${HAOS_AGENT_VERSION}_linux_${HA_ARCH}.deb"
    info "Downloading from: ${AGENT_URL}"
    wget -q -O /tmp/os-agent.deb "$AGENT_URL" || \
        error "Failed to download HA OS Agent. Check internet connection."

    dpkg -i /tmp/os-agent.deb
    rm -f /tmp/os-agent.deb
    success "HA OS Agent installed"
fi

# ── Step 8: Home Assistant Supervised ───────────────────────
header "Step 8/8 — Home Assistant Supervised"

if systemctl is-active --quiet hassio-supervisor 2>/dev/null; then
    success "HA Supervised already running"
else
    info "Downloading HA Supervised installer..."
    wget -q -O /tmp/homeassistant-supervised.deb \
        "https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb" || \
        error "Failed to download HA Supervised installer"

    info "Installing HA Supervised..."
    info "This pulls several Docker images — may take 5-15 minutes..."
    info "Do not interrupt this process."
    echo ""

    MACHINE="generic-x86-64"
    [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && MACHINE="raspberrypi4-64"

    MACHINE=${MACHINE} dpkg -i /tmp/homeassistant-supervised.deb || {
        apt-get install -f -y -qq
    }
    rm -f /tmp/homeassistant-supervised.deb

    # Wait for HA to come up
    info "Waiting for HA to start (up to 10 minutes for first boot)..."
    info "HA is downloading ~1GB of Docker images — be patient..."

    MAX_WAIT=600
    WAITED=0
    until curl -sf "http://localhost:8123/" >/dev/null 2>&1; do
        [[ $WAITED -ge $MAX_WAIT ]] && {
            warn "HA not responding after ${MAX_WAIT}s"
            warn "It may still be pulling images. Check:"
            warn "  sudo journalctl -fu hassio-supervisor"
            break
        }
        printf "."
        sleep 10
        WAITED=$((WAITED + 10))
    done
    echo ""
    curl -sf "http://localhost:8123/" >/dev/null 2>&1 && success "HA is responding!"
fi

# ── Summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║      Bootstrap Complete!                      ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BOLD}  Access:${NC}"
echo -e "  HA Web UI:  ${CYAN}http://${CURRENT_IP}:8123${NC}"
echo -e "  HA mDNS:    ${CYAN}http://konnectnest.local:8123${NC}"
echo -e "  SSH:        ${CYAN}ssh knadmin@${CURRENT_IP}${NC}"
echo ""
echo -e "${BOLD}  Next Steps:${NC}"
echo -e "  1. Open http://${CURRENT_IP}:8123 and complete HA onboarding"
echo -e "  2. Follow: PART-2-HA-INSTALL.md (HA configuration)"
echo -e "  3. Follow: PART-3-MQTT.md (Mosquitto MQTT broker)"
echo -e "  4. Follow: PART-4-ZIGBEE2MQTT.md (Zigbee integration)"
echo -e "  5. Follow: PART-5-KN-ADDON.md (Konnect Nest branding)"
echo ""
echo -e "${YELLOW}  ⚠  HA is still pulling Docker images in background.${NC}"
echo -e "${YELLOW}     If browser shows blank page, wait 5 min and refresh.${NC}"
echo ""
