#!/bin/bash
# SSH Knock — Uninstaller
# Stops daemon, restores SSH to normal CSF-managed access
# Run as root

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
    esac
done

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  SSH Knock — Uninstaller               ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

INSTALL_DIR="/opt/ssh-knock"

if [ ! -d "$INSTALL_DIR" ] && ! systemctl is-active ssh-knock >/dev/null 2>&1; then
    echo -e "${RED}Error: SSH Knock not installed${NC}"
    exit 1
fi

# Load config safely (no source)
SSH_PORT=""
KNOCK1=""
KNOCK2=""
KNOCK3=""
if [ -f "$INSTALL_DIR/config" ]; then
    SSH_PORT=$(grep '^SSH_PORT=' "$INSTALL_DIR/config" | cut -d= -f2)
    KNOCK1=$(grep '^KNOCK1=' "$INSTALL_DIR/config" | cut -d= -f2)
    KNOCK2=$(grep '^KNOCK2=' "$INSTALL_DIR/config" | cut -d= -f2)
    KNOCK3=$(grep '^KNOCK3=' "$INSTALL_DIR/config" | cut -d= -f2)
    echo "Current config:"
    echo "  SSH port:        $SSH_PORT"
    echo "  Knock sequence:  $KNOCK1 > $KNOCK2 > $KNOCK3"
else
    echo -e "${YELLOW}Warning: Config not found, will restore from backups${NC}"
fi

echo ""
echo "This will:"
echo "  1. Stop and remove the knock daemon"
echo "  2. Re-add SSH port to CSF allowed ports"
echo "  3. Restart CSF firewall"
echo "  4. Remove all SSH Knock files"
echo ""

if [ "$AUTO_YES" != "true" ]; then
    read -p "Proceed? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
fi

echo ""

# Remove all ssh-knock crons (safety + watchdog)
crontab -l 2>/dev/null | grep -v "ssh-knock" | crontab - 2>/dev/null || true

# Stop and remove systemd service
echo -n "Stopping knock daemon... "
systemctl stop ssh-knock 2>/dev/null
systemctl disable ssh-knock 2>/dev/null
rm -f /etc/systemd/system/ssh-knock.service
systemctl daemon-reload 2>/dev/null
echo -e "${GREEN}OK${NC}"

# Clean up temp state
rm -rf /tmp/ssh-knock-state

# Remove any CSF temp allows we created
echo -n "Removing temporary CSF allows... "
if [ -f /var/lib/csf/csf.tempallow ]; then
    grep -v "ssh-knock" /var/lib/csf/csf.tempallow > /var/lib/csf/csf.tempallow.tmp 2>/dev/null
    mv /var/lib/csf/csf.tempallow.tmp /var/lib/csf/csf.tempallow 2>/dev/null
fi
echo -e "${GREEN}OK${NC}"

# Restore SSH port to CSF config
echo -n "Restoring SSH port to CSF config... "
if [ -n "$SSH_PORT" ]; then
    # Surgically re-add SSH port to TCP_IN and TCP6_IN
    for KEY in TCP_IN TCP6_IN; do
        current=$(grep "^${KEY} = " /etc/csf/csf.conf | sed 's/.*= "//;s/"//')
        if ! echo ",$current," | grep -q ",${SSH_PORT},"; then
            sed -i "s/${KEY} = \"${current}\"/${KEY} = \"${current},${SSH_PORT}\"/" /etc/csf/csf.conf
        fi
    done
    echo -e "${GREEN}OK${NC}"
elif [ -f "$INSTALL_DIR/csf.conf.backup" ]; then
    # Fallback: restore entire backup if SSH_PORT is unknown
    cp "$INSTALL_DIR/csf.conf.backup" /etc/csf/csf.conf
    echo -e "${GREEN}OK (restored from backup)${NC}"
else
    echo -e "${YELLOW}No config or backup found — manually add your SSH port to TCP_IN in /etc/csf/csf.conf${NC}"
fi

# Also clean any leftover csfpost.sh rules from previous iptables-based installs
if [ -f /etc/csf/csfpost.sh ] && grep -q '# === SSH Knock' /etc/csf/csfpost.sh; then
    echo -n "Cleaning legacy csfpost.sh rules... "
    sed -i '/^$/N;/\n# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
    sed -i '/# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
    echo -e "${GREEN}OK${NC}"
fi

# Restart CSF
echo -n "Restarting CSF firewall... "
if csf -r > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED — check CSF manually${NC}"
fi

# Remove install directory
echo -n "Removing installation files... "
rm -rf "$INSTALL_DIR"
echo -e "${GREEN}OK${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Uninstall Complete                     ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "SSH port ${SSH_PORT:-22} is now open normally through CSF."
echo ""
