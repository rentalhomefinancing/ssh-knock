#!/bin/bash
# SSH Knock — Uninstaller
# Restores SSH to normal CSF-managed access
# Run as root

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  SSH Knock — Uninstaller               ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

INSTALL_DIR="/opt/ssh-knock"

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}Error: SSH Knock not installed ($INSTALL_DIR not found)${NC}"
    exit 1
fi

# Load config
if [ -f "$INSTALL_DIR/config" ]; then
    source "$INSTALL_DIR/config"
    echo "Current config:"
    echo "  SSH port:        $SSH_PORT"
    echo "  Knock sequence:  $KNOCK1 > $KNOCK2 > $KNOCK3"
else
    echo -e "${YELLOW}Warning: Config not found, will restore from backups${NC}"
fi

echo ""
echo "This will:"
echo "  1. Restore CSF config from backup (re-enables SSH port)"
echo "  2. Remove port knock rules from csfpost.sh"
echo "  3. Restart CSF firewall"
echo "  4. Remove all SSH Knock files"
echo ""
read -p "Proceed? [y/N]: " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Uninstall cancelled."
    exit 0
fi

echo ""

# Restore CSF config
echo -n "Restoring CSF config... "
if [ -f "$INSTALL_DIR/csf.conf.backup" ]; then
    cp "$INSTALL_DIR/csf.conf.backup" /etc/csf/csf.conf
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}No backup found — manually add port $SSH_PORT to TCP_IN in /etc/csf/csf.conf${NC}"
fi

# Remove knock rules from csfpost.sh
echo -n "Removing knock rules from csfpost.sh... "
if [ -f "$INSTALL_DIR/csfpost.sh.backup" ]; then
    cp "$INSTALL_DIR/csfpost.sh.backup" /etc/csf/csfpost.sh
elif [ -f /etc/csf/csfpost.sh ]; then
    sed -i '/# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
fi
echo -e "${GREEN}OK${NC}"

# Restart CSF
echo -n "Restarting CSF firewall... "
csf -r > /dev/null 2>&1
echo -e "${GREEN}OK${NC}"

# Flush our custom chains
iptables -F SSH_KNOCK 2>/dev/null || true
iptables -F SSH_KNOCK_S2 2>/dev/null || true
iptables -F SSH_KNOCK_S3 2>/dev/null || true
iptables -D INPUT -j SSH_KNOCK 2>/dev/null || true
iptables -X SSH_KNOCK 2>/dev/null || true
iptables -X SSH_KNOCK_S2 2>/dev/null || true
iptables -X SSH_KNOCK_S3 2>/dev/null || true

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
