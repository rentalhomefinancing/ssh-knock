#!/bin/bash
# SSH Knock — Uninstaller
# Restores SSH to normal CSF-managed access
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

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}Error: SSH Knock not installed ($INSTALL_DIR not found)${NC}"
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
echo "  1. Re-add SSH port to CSF allowed ports"
echo "  2. Remove port knock rules from csfpost.sh"
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

# Remove safety cron if present
crontab -l 2>/dev/null | grep -v "ssh-knock" | crontab - 2>/dev/null || true

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

# Remove knock rules from csfpost.sh
echo -n "Removing knock rules from csfpost.sh... "
if [ -f /etc/csf/csfpost.sh ]; then
    # Remove the SSH Knock block and any preceding blank line
    sed -i '/^$/N;/\n# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
    # Also catch if block starts without preceding blank line
    sed -i '/# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
fi
echo -e "${GREEN}OK${NC}"

# Restart CSF
echo -n "Restarting CSF firewall... "
if csf -r > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED — check CSF manually${NC}"
fi

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
