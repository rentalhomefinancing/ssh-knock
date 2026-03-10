#!/bin/bash
# regenerate-ports.sh — Regenerate SSH Knock port sequence
# Called by CWP admin module. Run as root.
# Permissions: chmod 755 (set by installer during deployment)
set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
INSTALL_DIR="/opt/ssh-knock"
CONFIG="$INSTALL_DIR/config"
LOCK_FILE="$INSTALL_DIR/.lock"
AUDIT_LOG="$INSTALL_DIR/audit.log"
TEMPLATES_DIR="$INSTALL_DIR/templates"
CLIENTS_DIR="$INSTALL_DIR/clients"

# =============================================================================
# Helpers
# =============================================================================
die() {
    echo "ERROR: $1" >&2
    exit 1
}

audit() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "[$timestamp] $1" >> "$AUDIT_LOG"
}

read_config_value() {
    # Read a KEY=VALUE from the config file without using source
    local key="$1"
    grep "^${key}=" "$CONFIG" 2>/dev/null | cut -d= -f2
}

# =============================================================================
# Pre-flight checks
# =============================================================================
if [ "$EUID" -ne 0 ]; then
    die "Must be run as root"
fi

if [ ! -f "$CONFIG" ]; then
    die "Config not found at $CONFIG"
fi

if ! systemctl is-active ssh-knock >/dev/null 2>&1; then
    die "ssh-knock daemon is not running — nothing to regenerate"
fi

# =============================================================================
# Acquire exclusive lock (prevents concurrent regeneration)
# =============================================================================
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    die "Another regeneration is already in progress (lock held on $LOCK_FILE)"
fi

# =============================================================================
# Read current config
# =============================================================================
SSH_PORT="$(read_config_value SSH_PORT)"
OLD_KNOCK1="$(read_config_value KNOCK1)"
OLD_KNOCK2="$(read_config_value KNOCK2)"
OLD_KNOCK3="$(read_config_value KNOCK3)"
KNOCK_TIMEOUT="$(read_config_value KNOCK_TIMEOUT)"
ACCESS_TIMEOUT="$(read_config_value ACCESS_TIMEOUT)"

# Defaults if not set
KNOCK_TIMEOUT="${KNOCK_TIMEOUT:-10}"
ACCESS_TIMEOUT="${ACCESS_TIMEOUT:-30}"

if [ -z "$SSH_PORT" ] || [ -z "$OLD_KNOCK1" ] || [ -z "$OLD_KNOCK2" ] || [ -z "$OLD_KNOCK3" ]; then
    die "Incomplete config — missing SSH_PORT or KNOCK ports"
fi

# Validate all values are numeric
for val in "$SSH_PORT" "$OLD_KNOCK1" "$OLD_KNOCK2" "$OLD_KNOCK3"; do
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        die "Config contains non-numeric port value: $val"
    fi
done

# =============================================================================
# Generate 3 new unique random ports
# =============================================================================
generate_port() {
    # Generate a random port in 10000-49999 that is:
    #   - not the SSH port
    #   - not already assigned to another new knock port
    #   - not currently in use (listening)
    # Args: $@ = ports to avoid (already-chosen knock ports)
    local port attempts=0
    local -a avoid=("$SSH_PORT" "$@")

    while true; do
        port=$(shuf -i 10000-49999 -n 1)
        attempts=$((attempts + 1))

        # Check against avoid list
        local conflict=false
        for blocked in "${avoid[@]}"; do
            if [ "$port" = "$blocked" ]; then
                conflict=true
                break
            fi
        done

        if [ "$conflict" = true ]; then
            if [ $attempts -gt 100 ]; then
                die "Could not find available port after 100 attempts"
            fi
            continue
        fi

        # Check the port is not currently in use
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            if [ $attempts -gt 100 ]; then
                die "Could not find available port after 100 attempts"
            fi
            continue
        fi

        echo "$port"
        return
    done
}

NEW_KNOCK1=$(generate_port "$OLD_KNOCK1" "$OLD_KNOCK2" "$OLD_KNOCK3")
NEW_KNOCK2=$(generate_port "$NEW_KNOCK1" "$OLD_KNOCK1" "$OLD_KNOCK2" "$OLD_KNOCK3")
NEW_KNOCK3=$(generate_port "$NEW_KNOCK1" "$NEW_KNOCK2" "$OLD_KNOCK1" "$OLD_KNOCK2" "$OLD_KNOCK3")

# =============================================================================
# Back up current config
# =============================================================================
cp "$CONFIG" "$INSTALL_DIR/config.pre-regenerate"

# =============================================================================
# Stop daemon
# =============================================================================
# ERR trap: if anything fails after daemon stop, rollback automatically
trap 'audit "ROLLBACK: unexpected script exit"; \
      cp "$INSTALL_DIR/config.pre-regenerate" "$CONFIG" 2>/dev/null; \
      systemctl start ssh-knock 2>/dev/null; \
      die "Unexpected error — rolled back to previous config"' ERR

systemctl stop ssh-knock || die "Failed to stop ssh-knock daemon"

# =============================================================================
# Write new config atomically (write to tmp, then mv)
# =============================================================================
cat > "${CONFIG}.tmp" << EOF
SSH_PORT=$SSH_PORT
KNOCK1=$NEW_KNOCK1
KNOCK2=$NEW_KNOCK2
KNOCK3=$NEW_KNOCK3
KNOCK_TIMEOUT=$KNOCK_TIMEOUT
ACCESS_TIMEOUT=$ACCESS_TIMEOUT
EOF
chmod 600 "${CONFIG}.tmp"
mv "${CONFIG}.tmp" "$CONFIG"

# =============================================================================
# Regenerate client scripts
# =============================================================================
HOSTNAME_VAL="$(hostname)"

regenerate_from_templates() {
    # Use template files with placeholder replacement
    local tpl out
    for tpl_file in knock.sh.tpl knock.ps1.tpl knock-gui.py.tpl knock-gui.ps1.tpl; do
        tpl="$TEMPLATES_DIR/$tpl_file"
        # Derive output filename by removing .tpl suffix
        out="$CLIENTS_DIR/${tpl_file%.tpl}"

        if [ ! -f "$tpl" ]; then
            continue
        fi

        sed \
            -e "s/%%SSH_PORT%%/$SSH_PORT/g" \
            -e "s/%%KNOCK1%%/$NEW_KNOCK1/g" \
            -e "s/%%KNOCK2%%/$NEW_KNOCK2/g" \
            -e "s/%%KNOCK3%%/$NEW_KNOCK3/g" \
            -e "s/%%HOSTNAME%%/$HOSTNAME_VAL/g" \
            "$tpl" > "$out"

        chmod 700 "$out"
    done
}

regenerate_via_sed_fallback() {
    # Fallback: replace old port values in existing client files
    for client_file in "$CLIENTS_DIR"/*; do
        [ -f "$client_file" ] || continue

        sed -i \
            -e "s/\b${OLD_KNOCK1}\b/${NEW_KNOCK1}/g" \
            -e "s/\b${OLD_KNOCK2}\b/${NEW_KNOCK2}/g" \
            -e "s/\b${OLD_KNOCK3}\b/${NEW_KNOCK3}/g" \
            "$client_file"

        chmod 700 "$client_file"
    done
}

if [ -d "$TEMPLATES_DIR" ] && ls "$TEMPLATES_DIR"/*.tpl >/dev/null 2>&1; then
    regenerate_from_templates
else
    regenerate_via_sed_fallback
fi

# =============================================================================
# Start daemon
# =============================================================================
if ! systemctl start ssh-knock; then
    # -------------------------------------------------------------------------
    # Rollback: restore old config, restart daemon, report error
    # -------------------------------------------------------------------------
    audit "ROLLBACK: daemon failed to start with new ports $NEW_KNOCK1 > $NEW_KNOCK2 > $NEW_KNOCK3"
    cp "$INSTALL_DIR/config.pre-regenerate" "$CONFIG"

    # Re-run client regeneration with old ports restored
    if [ -d "$TEMPLATES_DIR" ] && ls "$TEMPLATES_DIR"/*.tpl >/dev/null 2>&1; then
        # Config is restored, but templates use placeholders — need to regenerate
        # with the old values, which are now back in config. Re-read them.
        NEW_KNOCK1="$OLD_KNOCK1"
        NEW_KNOCK2="$OLD_KNOCK2"
        NEW_KNOCK3="$OLD_KNOCK3"
        regenerate_from_templates
    else
        # Sed fallback: swap the new ports back to old
        for client_file in "$CLIENTS_DIR"/*; do
            [ -f "$client_file" ] || continue
            sed -i \
                -e "s/${NEW_KNOCK1}/${OLD_KNOCK1}/g" \
                -e "s/${NEW_KNOCK2}/${OLD_KNOCK2}/g" \
                -e "s/${NEW_KNOCK3}/${OLD_KNOCK3}/g" \
                "$client_file"
        done
    fi

    systemctl start ssh-knock 2>/dev/null || true
    die "Daemon failed to start with new ports. Rolled back to previous config."
fi

# Clear ERR trap — daemon started successfully
trap - ERR

# =============================================================================
# Health check (retry loop instead of fixed sleep)
# =============================================================================
HEALTH_OK=false
for i in 1 2 3 4 5; do
    sleep 1
    if [ "$(systemctl is-active ssh-knock)" = "active" ]; then
        HEALTH_OK=true
        break
    fi
done

if [ "$HEALTH_OK" != "true" ]; then
    # Rollback
    audit "ROLLBACK: daemon not active after health check (ports: $NEW_KNOCK1 > $NEW_KNOCK2 > $NEW_KNOCK3)"
    systemctl stop ssh-knock 2>/dev/null || true
    cp "$INSTALL_DIR/config.pre-regenerate" "$CONFIG"

    if [ -d "$TEMPLATES_DIR" ] && ls "$TEMPLATES_DIR"/*.tpl >/dev/null 2>&1; then
        NEW_KNOCK1="$OLD_KNOCK1"
        NEW_KNOCK2="$OLD_KNOCK2"
        NEW_KNOCK3="$OLD_KNOCK3"
        regenerate_from_templates
    else
        for client_file in "$CLIENTS_DIR"/*; do
            [ -f "$client_file" ] || continue
            sed -i \
                -e "s/${NEW_KNOCK1}/${OLD_KNOCK1}/g" \
                -e "s/${NEW_KNOCK2}/${OLD_KNOCK2}/g" \
                -e "s/${NEW_KNOCK3}/${OLD_KNOCK3}/g" \
                "$client_file"
        done
    fi

    systemctl start ssh-knock 2>/dev/null || true
    die "Daemon not active after restart. Rolled back to previous config."
fi

# =============================================================================
# Dead-man's switch — auto-revert in 5 minutes unless cancelled
# =============================================================================
# Create a revert script that restores the pre-regenerate config
REVERT_SCRIPT="$INSTALL_DIR/revert-regen.sh"
cat > "$REVERT_SCRIPT" << 'REVERTEOF'
#!/bin/bash
# Auto-revert: restore pre-regenerate SSH Knock config
# Created by regenerate-ports.sh dead-man's switch
set +e  # Recovery script — must not abort on errors
INSTALL_DIR="/opt/ssh-knock"
# Staleness check — don't revert if backup is more than 30 minutes old
CREATED=$(stat -c %Y "$INSTALL_DIR/config.pre-regenerate" 2>/dev/null || echo 0)
NOW=$(date +%s)
if [ $(( NOW - CREATED )) -gt 1800 ]; then
    crontab -l 2>/dev/null | grep -v 'ssh-knock-regen-safety' | crontab - 2>/dev/null
    rm -f "$INSTALL_DIR/revert-regen.sh"
    exit 0
fi
if [ -f "$INSTALL_DIR/config.pre-regenerate" ]; then
    systemctl stop ssh-knock 2>/dev/null || true
    cp "$INSTALL_DIR/config.pre-regenerate" "$INSTALL_DIR/config"
    systemctl start ssh-knock 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') DEAD-MAN-SWITCH: reverted to pre-regenerate config" >> "$INSTALL_DIR/audit.log"
fi
# Clean up the cron entry and this script
crontab -l 2>/dev/null | grep -v 'ssh-knock-regen-safety' | crontab - 2>/dev/null
rm -f "$INSTALL_DIR/revert-regen.sh"
REVERTEOF
chmod 755 "$REVERT_SCRIPT"

# Remove any previous safety cron, then schedule revert in 5 minutes
REVERT_TIME=$(date -d '+15 minutes' '+%M %H %d %m *')
(crontab -l 2>/dev/null | grep -v 'ssh-knock-regen-safety'; echo "$REVERT_TIME $REVERT_SCRIPT # ssh-knock-regen-safety") | crontab -

# =============================================================================
# Audit log
# =============================================================================
audit "REGENERATE: old=$OLD_KNOCK1,$OLD_KNOCK2,$OLD_KNOCK3 new=$NEW_KNOCK1,$NEW_KNOCK2,$NEW_KNOCK3 ssh_port=$SSH_PORT"

# =============================================================================
# Success output (parsed by CWP PHP module)
# =============================================================================
echo "OK: Ports regenerated. New sequence: $NEW_KNOCK1 > $NEW_KNOCK2 > $NEW_KNOCK3"
echo ""
echo "SAFETY: Auto-revert scheduled in 15 minutes."
echo "After confirming the new ports work, cancel the safety revert:"
echo "  crontab -l | grep -v 'ssh-knock-regen-safety' | crontab -"
