#!/usr/bin/env bash
# ============================================================
#  Konnect Nest — VirtualBox VM Bootstrap Script
#  Run this ONCE on a fresh Ubuntu 22.04 / Debian 12 VM
#  BEFORE installing Home Assistant OS
#
#  What this does:
#    1.  Verifies OS compatibility
#    2.  Sets a static IP (avoids DHCP drift)
#    3.  Sets hostname to konnectnest
#    4.  Installs all HA OS Agent prerequisites
#    5.  Installs Docker Engine
#    6.  Installs HA OS Agent (required for HA Supervised)
#    7.  Installs Home Assistant Supervised
#    8.  Verifies everything is running
#    9.  Prints access instructions
#
#  Usage:
#    chmod +x bootstrap.sh
#    sudo ./bootstrap.sh
#
#  Or run remotely from your admin machine:
#    ssh user@vm-ip 'bash -s' < bootstrap.sh
#
#  Requirements:
#    - Ubuntu 22.04 LTS or Debian 12 (fresh install)
#    - At least 4GB RAM, 32GB disk
#    - Internet access
#    - Run as root or with sudo
# ============================================================

set -euo pipefail

# ─── Must run as root ──────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo ./bootstrap.sh"
    exit 1
fi

# ─── Colours ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[KN]${NC} $*"; }
success() { echo -e "${GREEN}[KN] ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}[KN] ⚠${NC} $*"; }
error()   { echo -e "${RED}[KN] ✗${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}";
            echo -e "${BOLD}${CYAN}  $*${NC}";
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"; }

# ─── Configuration — edit these before running ─────────────
HOSTNAME="konnectnest"
HA_VERSION="2025.1.0"           # HA version to install
HAOS_AGENT_VERSION="2.0.0"     # HA OS Agent version
# Static IP config — set to match your friend's network
# Leave STATIC_IP empty to skip static IP setup (use DHCP)
STATIC_IP=""                    # e.g. "192.168.1.100"
GATEWAY=""                      # e.g. "192.168.1.1"
DNS="8.8.8.8,8.8.4.4"          # Google DNS (or use router IP)
INTERFACE=""                    # Leave empty to auto-detect

# ─── Auto-detect network interface ─────────────────────────
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    info "Auto-detected network interface: ${INTERFACE}"
fi

# ─── Banner ────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
  ██╗  ██╗ ██████╗ ███╗   ██╗███╗   ██╗███████╗ ██████╗████████╗
  ██║ ██╔╝██╔═══██╗████╗  ██║████╗  ██║██╔════╝██╔════╝╚══██╔══╝
  █████╔╝ ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║        ██║
  ██╔═██╗ ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║        ██║
  ██║  ██╗╚██████╔╝██║ ╚████║██║ ╚████║███████╗╚██████╗   ██║
  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝ ╚═════╝   ╚═╝
  ███╗   ██╗███████╗███████╗████████╗
  ████╗  ██║██╔════╝██╔════╝╚══██╔══╝
  ██╔██╗ ██║█████╗  ███████╗   ██║
  ██║╚██╗██║██╔══╝  ╚════██║   ██║
  ██║ ╚████║███████╗███████║   ██║
  ╚═╝  ╚═══╝╚══════╝╚══════╝   ╚═╝
BANNER
echo -e "${NC}"
echo -e "${BOLD}  Konnect Nest VM Bootstrap${NC}"
echo -e "  Installing Home Assistant + Konnect Nest branding"
echo -e "  Target HA version: ${HA_VERSION}\n"

# ─── Step 1: OS Compatibility Check ────────────────────────
header "Step 1/9 — Checking OS compatibility"

OS_ID=$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
OS_VER=$(grep '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')

info "Detected OS: ${OS_ID} ${OS_VER}"

if [[ "$OS_ID" == "ubuntu" && "$OS_VER" == "22.04" ]]; then
    success "Ubuntu 22.04 LTS — fully supported"
elif [[ "$OS_ID" == "debian" && "$OS_VER" == "12" ]]; then
    success "Debian 12 — fully supported"
elif [[ "$OS_ID" == "ubuntu" && "$OS_VER" == "24.04" ]]; then
    success "Ubuntu 24.04 LTS — supported (experimental)"
else
    warn "OS ${OS_ID} ${OS_VER} not officially tested"
    warn "Supported: Ubuntu 22.04, Ubuntu 24.04, Debian 12"
    read -rp "Continue anyway? [y/N] " cont
    [[ "$cont" =~ ^[Yy]$ ]] || exit 0
fi

# ─── Step 2: Set Hostname ───────────────────────────────────
header "Step 2/9 — Setting hostname"

CURRENT_HOSTNAME=$(hostname)
if [[ "$CURRENT_HOSTNAME" != "$HOSTNAME" ]]; then
    hostnamectl set-hostname "$HOSTNAME"
    # Update /etc/hosts
    sed -i "s/127.0.1.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts 2>/dev/null || \
        echo "127.0.1.1	${HOSTNAME}" >> /etc/hosts
    success "Hostname set to: ${HOSTNAME}"
    info "mDNS: ${HOSTNAME}.local will be available after reboot"
else
    success "Hostname already set to: ${HOSTNAME}"
fi

# ─── Step 3: Static IP (Optional) ──────────────────────────
header "Step 3/9 — Network configuration"

if [[ -n "$STATIC_IP" && -n "$GATEWAY" ]]; then
    info "Setting static IP: ${STATIC_IP}"

    # Use NetworkManager (Ubuntu 22.04 standard)
    if command -v nmcli &> /dev/null; then
        CON_NAME=$(nmcli -t -f NAME connection show --active | head -1)
        nmcli connection modify "$CON_NAME" \
            ipv4.method manual \
            ipv4.addresses "${STATIC_IP}/24" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS"
        nmcli connection up "$CON_NAME"
        success "Static IP set via NetworkManager: ${STATIC_IP}"
    else
        warn "NetworkManager not found — configuring via netplan"
        cat > /etc/netplan/01-konnectnest.yaml << NETPLAN
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
        addresses: [$(echo $DNS | tr ',' ' ')]
NETPLAN
        netplan apply
        success "Static IP set via netplan: ${STATIC_IP}"
    fi
else
    info "STATIC_IP not set — keeping DHCP"
    CURRENT_IP=$(hostname -I | awk '{print $1}')
    warn "Current IP (DHCP): ${CURRENT_IP}"
    warn "This IP may change on router restart"
    warn "Set STATIC_IP in bootstrap.sh for a permanent IP"
fi

# ─── Step 4: System Update ─────────────────────────────────
header "Step 4/9 — System update"
info "Updating package lists..."
apt-get update -qq
info "Upgrading packages..."
apt-get upgrade -y -qq
success "System updated"

# ─── Step 5: Install Prerequisites ─────────────────────────
header "Step 5/9 — Installing prerequisites"

info "Installing required packages..."
apt-get install -y -qq \
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
    avahi-utils

# Enable and start required services
systemctl enable --now avahi-daemon
systemctl enable --now NetworkManager

success "Prerequisites installed"

# ─── Step 6: Install Docker ────────────────────────────────
header "Step 6/9 — Installing Docker"

if command -v docker &> /dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    success "Docker already installed: ${DOCKER_VER}"
else
    info "Installing Docker Engine..."

    # Add Docker's official GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/${OS_ID}/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${OS_ID} \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Enable Docker service
    systemctl enable --now docker

    success "Docker installed: $(docker --version)"
fi

# ─── Step 7: Install HA OS Agent ───────────────────────────
header "Step 7/9 — Installing Home Assistant OS Agent"

if command -v ha &> /dev/null; then
    success "HA OS Agent already installed"
else
    info "Downloading HA OS Agent v${HAOS_AGENT_VERSION}..."
    ARCH=$(dpkg --print-architecture)
    # Map debian arch to HA arch
    case "$ARCH" in
        amd64)  HA_ARCH="amd64" ;;
        arm64)  HA_ARCH="aarch64" ;;
        armhf)  HA_ARCH="armv7" ;;
        *)      error "Unsupported architecture: ${ARCH}" ;;
    esac

    AGENT_URL="https://github.com/home-assistant/os-agent/releases/download/${HAOS_AGENT_VERSION}/os-agent_${HAOS_AGENT_VERSION}_linux_${HA_ARCH}.deb"
    wget -q -O /tmp/os-agent.deb "$AGENT_URL"
    dpkg -i /tmp/os-agent.deb
    rm /tmp/os-agent.deb

    # Verify
    if gdbus introspect --system --dest io.hass.os \
        --object-path /io/hass/os &> /dev/null; then
        success "HA OS Agent installed and running"
    else
        warn "OS Agent installed but not responding yet (may need a moment)"
    fi
fi

# ─── Step 8: Install Home Assistant Supervised ─────────────
header "Step 8/9 — Installing Home Assistant Supervised"

if systemctl is-active --quiet hassio-supervisor 2>/dev/null; then
    success "HA Supervised already installed and running"
else
    info "Downloading HA Supervised installer..."
    wget -q -O /tmp/homeassistant-supervised.deb \
        "https://github.com/home-assistant/supervised-installer/releases/latest/download/homeassistant-supervised.deb"

    info "Installing HA Supervised (this takes 5-10 minutes)..."
    info "It will pull several Docker images — please be patient..."

    # Install with machine type for generic x86/VM
    MACHINE_TYPE="generic-x86-64"
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        MACHINE_TYPE="raspberrypi4-64"
    fi

    MACHINE=${MACHINE_TYPE} dpkg -i /tmp/homeassistant-supervised.deb || true
    apt-get install -f -y -qq  # Fix any dependency issues
    rm /tmp/homeassistant-supervised.deb

    info "Waiting for HA Supervisor to start (up to 5 minutes)..."
    MAX_WAIT=300
    WAITED=0
    until curl -sf "http://localhost:8123/" > /dev/null 2>&1; do
        if [[ $WAITED -ge $MAX_WAIT ]]; then
            warn "HA not responding after ${MAX_WAIT}s"
            warn "It may still be pulling Docker images"
            warn "Check: journalctl -fu hassio-supervisor"
            break
        fi
        printf "."
        sleep 5
        WAITED=$((WAITED + 5))
    done
    echo ""

    if curl -sf "http://localhost:8123/" > /dev/null 2>&1; then
        success "Home Assistant is running!"
    fi
fi

# ─── Step 9: Summary ───────────────────────────────────────
header "Step 9/9 — Summary"

CURRENT_IP=$(hostname -I | awk '{print $1}')

echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║      Konnect Nest VM Ready!              ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}  Access Details:${NC}"
echo -e "  Web (IP):    ${CYAN}http://${CURRENT_IP}:8123${NC}"
echo -e "  Web (mDNS):  ${CYAN}http://${HOSTNAME}.local:8123${NC}"
echo ""
echo -e "${BOLD}  Next Steps:${NC}"
echo -e "  1. Open ${CYAN}http://${CURRENT_IP}:8123${NC} in your browser"
echo -e "  2. Complete the HA onboarding (create account, set location)"
echo -e "  3. Install the Konnect Nest add-on:"
echo -e "     Settings → Add-ons → Store → ⋮ → Repositories"
echo -e "     Add: ${CYAN}https://github.com/roarbis/KN-Addon${NC}"
echo -e "     Then install 'Konnect Nest' from the store"
echo -e "  4. On iPhone: Safari → Add to Home Screen → 'Konnect Nest'"
echo ""
echo -e "${BOLD}  System Info:${NC}"
echo -e "  Hostname:  ${HOSTNAME} (${HOSTNAME}.local)"
echo -e "  IP:        ${CURRENT_IP}"
echo -e "  HA Port:   8123"
echo -e "  Docker:    $(docker --version | awk '{print $3}' | tr -d ',')"
echo ""
echo -e "${YELLOW}  Note: If HA is still starting, wait 5 minutes and refresh.${NC}"
echo -e "${YELLOW}  It pulls ~1GB of Docker images on first boot.${NC}"
echo ""
