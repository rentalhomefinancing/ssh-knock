#!/bin/bash
# SSH Knock — CWP Module Installer
# Installs the SSH Knock admin panel into CWP (Control Web Panel)
# Run as root from the cwp-module/ directory

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/ssh-knock"
CWP_MODULES="/usr/local/cwpsrv/htdocs/resources/admin/modules"
THIRDPARTY="/usr/local/cwpsrv/htdocs/resources/admin/include/3rdparty.php"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SSH Knock — CWP Module Installer      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# --- Pre-flight checks ---

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

if [ ! -d "$CWP_MODULES" ]; then
    echo -e "${RED}Error: CWP modules directory not found at $CWP_MODULES${NC}"
    echo "Is CWP installed?"
    exit 1
fi

if [ ! -f "$INSTALL_DIR/config" ]; then
    echo -e "${RED}Error: SSH Knock config not found at $INSTALL_DIR/config${NC}"
    echo "Install SSH Knock first (./install.sh)."
    exit 1
fi

if [ -f "$CWP_MODULES/ssh_knock.php" ]; then
    echo -e "${YELLOW}SSH Knock CWP module is already installed.${NC}"
    echo "To reinstall, run the uninstaller first: /opt/ssh-knock/uninstall-cwp-module.sh"
    exit 0
fi

# Verify required source files exist
for src_file in ssh_knock.php regenerate-ports.sh uninstall-cwp-module.sh; do
    [ -f "$SCRIPT_DIR/$src_file" ] || {
        echo -e "${RED}Error: $SCRIPT_DIR/$src_file not found${NC}"
        echo "Run this script from the cwp-module/ directory."
        exit 1
    }
done

# Load config (no source — parse safely)
SSH_PORT=$(grep '^SSH_PORT=' "$INSTALL_DIR/config" | cut -d= -f2)
KNOCK1=$(grep '^KNOCK1=' "$INSTALL_DIR/config" | cut -d= -f2)
KNOCK2=$(grep '^KNOCK2=' "$INSTALL_DIR/config" | cut -d= -f2)
KNOCK3=$(grep '^KNOCK3=' "$INSTALL_DIR/config" | cut -d= -f2)

echo "SSH Knock config detected:"
echo "  SSH port:        $SSH_PORT"
echo "  Knock sequence:  $KNOCK1 > $KNOCK2 > $KNOCK3"
echo ""
echo -e "${GREEN}Installing CWP module...${NC}"
echo ""

# --- 1. Create backup directory ---

echo -n "Creating backup directory... "
mkdir -p "$INSTALL_DIR/backups"
echo -e "${GREEN}OK${NC}"

# --- 2. Start manifest ---

MANIFEST="$INSTALL_DIR/cwp-module-manifest.txt"
echo "# SSH Knock CWP Module Manifest" > "$MANIFEST"
echo "# Installed: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$MANIFEST"
echo "# This file is used by uninstall-cwp-module.sh to cleanly reverse the install" >> "$MANIFEST"
echo "" >> "$MANIFEST"

# --- 3. Copy ssh_knock.php to CWP modules ---

echo -n "Installing CWP module page... "
cp "$SCRIPT_DIR/ssh_knock.php" "$CWP_MODULES/ssh_knock.php"
chmod 644 "$CWP_MODULES/ssh_knock.php"
echo "FILE_CREATED=$CWP_MODULES/ssh_knock.php" >> "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# --- 4. Copy regenerate-ports.sh ---

echo -n "Installing port regeneration script... "
cp "$SCRIPT_DIR/regenerate-ports.sh" "$INSTALL_DIR/regenerate-ports.sh"
chmod 755 "$INSTALL_DIR/regenerate-ports.sh"
echo "SCRIPT_INSTALLED=$INSTALL_DIR/regenerate-ports.sh" >> "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# --- 5. Copy uninstall-cwp-module.sh ---

echo -n "Installing CWP module uninstaller... "
cp "$SCRIPT_DIR/uninstall-cwp-module.sh" "$INSTALL_DIR/uninstall-cwp-module.sh"
chmod 755 "$INSTALL_DIR/uninstall-cwp-module.sh"
echo "SCRIPT_INSTALLED=$INSTALL_DIR/uninstall-cwp-module.sh" >> "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# --- 6. Create client templates with placeholders ---

echo -n "Creating client templates... "
mkdir -p "$INSTALL_DIR/templates"
echo "DIR_CREATED=$INSTALL_DIR/templates" >> "$MANIFEST"

for client in knock.sh knock.ps1 knock-gui.py knock-gui.ps1; do
    src="$INSTALL_DIR/clients/$client"
    if [ -f "$src" ]; then
        tpl="$INSTALL_DIR/templates/${client}.tpl"
        # Read the client script and replace current port values with placeholders
        sed \
            -e "s/${KNOCK1}/%%KNOCK1%%/g" \
            -e "s/${KNOCK2}/%%KNOCK2%%/g" \
            -e "s/${KNOCK3}/%%KNOCK3%%/g" \
            -e "s/${SSH_PORT}/%%SSH_PORT%%/g" \
            "$src" > "$tpl"
        chmod 644 "$tpl"
    fi
done
echo -e "${GREEN}OK${NC}"

# --- 7. Backup 3rdparty.php ---

echo -n "Backing up 3rdparty.php... "
if [ ! -f "$THIRDPARTY" ]; then
    echo -e "${RED}FAILED${NC}"
    echo -e "${RED}Error: $THIRDPARTY not found${NC}"
    exit 1
fi
cp -p "$THIRDPARTY" "$INSTALL_DIR/backups/3rdparty.php.pre-cwp"
echo "BACKUP=$INSTALL_DIR/backups/3rdparty.php.pre-cwp" >> "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# --- 8. Add menu entry to 3rdparty.php (idempotent) ---

echo -n "Adding menu entry to CWP... "
if ! grep -q 'module=ssh_knock' "$THIRDPARTY"; then
    echo '<!-- SSH_KNOCK_START --><li><a href="index.php?module=ssh_knock"><span class="icon16 icomoon-icon-lock"></span>SSH Knock</a></li><!-- SSH_KNOCK_END -->' >> "$THIRDPARTY"
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}already present${NC}"
fi
echo "FILE_MODIFIED=$THIRDPARTY" >> "$MANIFEST"
echo "MENU_ADDED=ssh_knock" >> "$MANIFEST"

# --- 9. Create logrotate config ---

echo -n "Creating logrotate config... "
cat > /etc/logrotate.d/ssh-knock << 'LOGEOF'
/var/log/ssh-knock.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
}
LOGEOF
echo "FILE_CREATED=/etc/logrotate.d/ssh-knock" >> "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# --- 10. Done ---

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  CWP Module Installed                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "SSH Knock CWP module installed."
echo ""
echo -e "  Access:    ${YELLOW}https://$(hostname):2031/index.php?module=ssh_knock${NC}"
echo -e "  Manifest:  ${YELLOW}$MANIFEST${NC}"
echo -e "  Uninstall: ${YELLOW}/opt/ssh-knock/uninstall-cwp-module.sh${NC}"
echo ""
