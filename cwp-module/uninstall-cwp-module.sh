#!/bin/bash
# SSH Knock — CWP Module Uninstaller
# Removes the CWP admin panel module only — SSH Knock itself is NOT affected
# Run as root

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/ssh-knock"
MANIFEST="$INSTALL_DIR/cwp-module-manifest.txt"
THIRDPARTY="/usr/local/cwpsrv/htdocs/resources/admin/include/3rdparty.php"

# Parse arguments
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
    esac
done

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  SSH Knock — CWP Module Uninstaller    ${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# --- Pre-flight checks ---

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo -e "${RED}Error: Manifest not found at $MANIFEST${NC}"
    echo "The CWP module may not be installed."
    echo ""
    echo "If it was installed manually, remove these files:"
    echo "  /usr/local/cwpsrv/htdocs/resources/admin/modules/ssh_knock.php"
    echo "  /opt/ssh-knock/regenerate-ports.sh"
    echo "  /opt/ssh-knock/templates/"
    echo "  /etc/logrotate.d/ssh-knock"
    echo "And remove the SSH Knock menu entry from 3rdparty.php."
    exit 1
fi

# --- Show what will be removed ---

echo "The following will be removed:"
echo ""

while IFS= read -r line; do
    # Skip comments and blanks
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    TYPE="${line%%=*}"
    VALUE="${line#*=}"

    case "$TYPE" in
        FILE_CREATED)
            echo "  [file]   $VALUE" ;;
        SCRIPT_INSTALLED)
            echo "  [script] $VALUE" ;;
        DIR_CREATED)
            echo "  [dir]    $VALUE" ;;
        MENU_ADDED)
            echo "  [menu]   SSH Knock entry in 3rdparty.php" ;;
        FILE_MODIFIED)
            echo "  [config] $VALUE (menu entry will be removed)" ;;
        BACKUP)
            echo "  [backup] $VALUE (used for fallback, then removed)" ;;
    esac
done < "$MANIFEST"

echo ""
echo -e "${YELLOW}NOTE: This only removes the CWP module.${NC}"
echo "SSH Knock itself (daemon, config, CSF changes) is NOT affected."
echo "To fully uninstall SSH Knock, use: /opt/ssh-knock/uninstall.sh"
echo ""

# --- Confirm unless --yes ---

if [ "$AUTO_YES" != "true" ]; then
    read -p "Proceed? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Uninstall cancelled."
        exit 0
    fi
fi

echo ""

# --- Process manifest entries ---

BACKUP_FILE=""
SELF_SCRIPT="$INSTALL_DIR/uninstall-cwp-module.sh"
SKIP_SELF=false

while IFS= read -r line; do
    # Skip comments and blanks
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue

    TYPE="${line%%=*}"
    VALUE="${line#*=}"

    case "$TYPE" in
        FILE_CREATED)
            if [ -f "$VALUE" ]; then
                rm -f "$VALUE"
                echo -e "Removed: ${GREEN}$VALUE${NC}"
            else
                echo -e "Skipped: ${YELLOW}$VALUE${NC} (already removed)"
            fi
            ;;

        SCRIPT_INSTALLED)
            # Defer removal of uninstall script itself until the very end
            if [ "$VALUE" = "$SELF_SCRIPT" ]; then
                SKIP_SELF=true
                continue
            fi
            if [ -f "$VALUE" ]; then
                rm -f "$VALUE"
                echo -e "Removed: ${GREEN}$VALUE${NC}"
            else
                echo -e "Skipped: ${YELLOW}$VALUE${NC} (already removed)"
            fi
            ;;

        DIR_CREATED)
            if [ -d "$VALUE" ]; then
                rm -rf "$VALUE"
                echo -e "Removed: ${GREEN}$VALUE${NC}"
            else
                echo -e "Skipped: ${YELLOW}$VALUE${NC} (already removed)"
            fi
            ;;

        MENU_ADDED)
            echo -n "Removing menu entry from 3rdparty.php... "
            if [ -f "$THIRDPARTY" ]; then
                # Remove the sentinel-wrapped menu entry
                sed -i '/<!-- SSH_KNOCK_START -->/,/<!-- SSH_KNOCK_END -->/d' "$THIRDPARTY"

                # Verify removal
                if grep -q 'module=ssh_knock' "$THIRDPARTY"; then
                    echo -e "${RED}FAILED${NC}"
                    echo -e "${YELLOW}Warning: Could not remove menu entry via sed.${NC}"
                    # Try restoring from backup
                    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
                        echo -n "Restoring 3rdparty.php from backup... "
                        cp -p "$BACKUP_FILE" "$THIRDPARTY"
                        if grep -q 'module=ssh_knock' "$THIRDPARTY"; then
                            echo -e "${RED}FAILED${NC}"
                            echo -e "${YELLOW}Warning: Menu entry still present. Remove manually from:${NC}"
                            echo "  $THIRDPARTY"
                        else
                            echo -e "${GREEN}OK${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Warning: No backup available. Remove the SSH Knock entry manually from:${NC}"
                        echo "  $THIRDPARTY"
                    fi
                else
                    # Validate PHP syntax if php is available
                    if command -v php &>/dev/null; then
                        if php -l "$THIRDPARTY" >/dev/null 2>&1; then
                            echo -e "${GREEN}OK${NC}"
                        else
                            echo -e "${YELLOW}OK (removed, but PHP syntax warning)${NC}"
                            echo -e "${YELLOW}Restoring from backup to be safe...${NC}"
                            if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
                                cp -p "$BACKUP_FILE" "$THIRDPARTY"
                                echo -e "${GREEN}Restored from backup${NC}"
                            fi
                        fi
                    else
                        echo -e "${GREEN}OK${NC}"
                    fi
                fi
            else
                echo -e "${YELLOW}skipped (file not found)${NC}"
            fi
            ;;

        BACKUP)
            # Save path for potential fallback use, remove at end
            BACKUP_FILE="$VALUE"
            ;;

        FILE_MODIFIED)
            # No action needed — handled by MENU_ADDED
            ;;
    esac
done < "$MANIFEST"

# --- Final cleanup ---

echo ""
echo -n "Removing manifest... "
rm -f "$MANIFEST"
echo -e "${GREEN}OK${NC}"

# Remove backup file
if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    echo -n "Removing backup... "
    rm -f "$BACKUP_FILE"
    echo -e "${GREEN}OK${NC}"
fi

# Remove backups directory if empty
echo -n "Cleaning up backup directory... "
rmdir "$INSTALL_DIR/backups" 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${YELLOW}skipped (not empty or missing)${NC}"

# Remove uninstall script itself (last action)
if [ "$SKIP_SELF" = "true" ] && [ -f "$SELF_SCRIPT" ]; then
    rm -f "$SELF_SCRIPT"
    echo -e "Removed: ${GREEN}$SELF_SCRIPT${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  CWP Module Uninstalled                ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "CWP module uninstalled. SSH Knock itself is NOT affected."
echo ""
