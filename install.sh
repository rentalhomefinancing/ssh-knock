#!/bin/bash
# SSH Knock — Port Knocking for CSF Firewalls
# Uses a daemon + CSF's native temp-allow (csf -ta) instead of custom iptables chains
# CSF manages all firewall rules — we never touch iptables directly
# Run as root

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/ssh-knock"

# --- Rollback function ---
rollback() {
    echo ""
    echo -e "${RED}Rolling back changes...${NC}"
    # Stop and remove daemon
    systemctl stop ssh-knock 2>/dev/null
    systemctl disable ssh-knock 2>/dev/null
    rm -f /etc/systemd/system/ssh-knock.service
    systemctl daemon-reload 2>/dev/null
    # Restore CSF config
    if [ -f "$INSTALL_DIR/csf.conf.backup" ]; then
        cp "$INSTALL_DIR/csf.conf.backup" /etc/csf/csf.conf
    fi
    csf -r > /dev/null 2>&1 || true
    # Remove safety cron
    crontab -l 2>/dev/null | grep -v "ssh-knock" | crontab - 2>/dev/null
    echo -e "${YELLOW}Rolled back. SSH port $SSH_PORT should be open again.${NC}"
}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  SSH Knock — Port Knock Installer      ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

# Duplicate install protection
if systemctl is-active ssh-knock >/dev/null 2>&1; then
    echo -e "${RED}Error: SSH Knock is already running.${NC}"
    echo "Run ./uninstall.sh first, then reinstall."
    exit 1
fi

# Check CSF
if [ ! -f /etc/csf/csf.conf ]; then
    echo -e "${RED}Error: CSF firewall not found at /etc/csf/csf.conf${NC}"
    echo "This tool requires ConfigServer Security & Firewall (CSF)."
    exit 1
fi

if ! command -v csf &>/dev/null; then
    echo -e "${RED}Error: csf command not found${NC}"
    exit 1
fi

# Check tcpdump
if ! command -v tcpdump &>/dev/null; then
    echo -e "${RED}Error: tcpdump not found. Install it: yum install tcpdump${NC}"
    exit 1
fi

# Detect SSH port
SSH_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}

echo "Detected SSH port: $SSH_PORT"
read -p "SSH port to protect [$SSH_PORT]: " USER_SSH_PORT
SSH_PORT=${USER_SSH_PORT:-$SSH_PORT}

# Validate SSH port
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo -e "${RED}Error: Invalid port number${NC}"
    exit 1
fi

# Generate random knock ports (high range, avoid common services)
generate_port() {
    local port attempts=0
    while true; do
        port=$(shuf -i 10000-49999 -n 1 2>/dev/null || echo $((RANDOM % 40000 + 10000)))
        attempts=$((attempts + 1))
        if ! ss -tlnp 2>/dev/null | grep -q ":$port " && \
           [ "$port" != "${KNOCK1:-0}" ] && [ "$port" != "${KNOCK2:-0}" ] && \
           [ "$port" != "$SSH_PORT" ]; then
            echo $port
            return
        fi
        if [ $attempts -gt 100 ]; then
            echo -e "${RED}Error: Could not find available knock ports${NC}" >&2
            exit 1
        fi
    done
}

KNOCK1=$(generate_port)
KNOCK2=$(generate_port)
KNOCK3=$(generate_port)

echo ""
echo -e "${YELLOW}Configuration:${NC}"
echo "  SSH port:        $SSH_PORT"
echo "  Knock sequence:  $KNOCK1 > $KNOCK2 > $KNOCK3"
echo "  Knock timeout:   10 seconds between each knock"
echo "  Access window:   30 seconds after successful knock"
echo ""
echo -e "${YELLOW}How it works:${NC}"
echo "  1. SSH port $SSH_PORT is removed from CSF allowed ports"
echo "  2. A daemon watches for TCP packets to ports $KNOCK1, $KNOCK2, $KNOCK3"
echo "  3. On correct knock, CSF temporarily allows YOUR IP for 30 seconds"
echo "  4. Your current SSH session will NOT be interrupted"
echo "  5. CSF manages ALL firewall rules — zero custom iptables"
echo ""
echo -e "${RED}IMPORTANT: Keep this SSH session open after install!${NC}"
echo "Test the knock from another terminal before closing this one."
echo ""
read -p "Proceed? [y/N]: " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Installing...${NC}"

# Create install directory
mkdir -p "$INSTALL_DIR/clients"

# Save config
echo -n "Writing configuration... "
cat > "$INSTALL_DIR/config" << EOF
SSH_PORT=$SSH_PORT
KNOCK1=$KNOCK1
KNOCK2=$KNOCK2
KNOCK3=$KNOCK3
KNOCK_TIMEOUT=10
ACCESS_TIMEOUT=30
EOF
chmod 600 "$INSTALL_DIR/config"
echo -e "${GREEN}OK${NC}"

# Backup CSF config
echo -n "Backing up CSF config... "
cp /etc/csf/csf.conf "$INSTALL_DIR/csf.conf.backup"
echo -e "${GREEN}OK${NC}"

# Remove SSH port from CSF TCP_IN and TCP6_IN using Python for reliable CSV removal
echo -n "Removing port $SSH_PORT from CSF allowed ports... "
python3 -c "
import re, sys
port = sys.argv[1]
with open('/etc/csf/csf.conf', 'r') as f:
    content = f.read()
for key in ['TCP_IN', 'TCP6_IN']:
    def fix(m):
        ports = [p.strip() for p in m.group(1).split(',')]
        ports = [p for p in ports if p != port]
        return key + ' = \"' + ','.join(ports) + '\"'
    content = re.sub(key + r' = \"([^\"]+)\"', fix, content)
with open('/etc/csf/csf.conf', 'w') as f:
    f.write(content)
" "$SSH_PORT" || { echo -e "${RED}FAILED${NC}"; rollback; exit 1; }
echo -e "${GREEN}OK${NC}"

# Install the knock daemon
echo -n "Installing knock daemon... "
cat > "$INSTALL_DIR/knock-daemon.sh" << 'DAEMONEOF'
#!/bin/bash
# SSH Knock Daemon — detects knock sequence via tcpdump, grants access via CSF
# This daemon works WITH CSF — never touches iptables directly.

CONFIG="/opt/ssh-knock/config"
KNOCK1=$(grep '^KNOCK1=' "$CONFIG" | cut -d= -f2)
KNOCK2=$(grep '^KNOCK2=' "$CONFIG" | cut -d= -f2)
KNOCK3=$(grep '^KNOCK3=' "$CONFIG" | cut -d= -f2)
SSH_PORT=$(grep '^SSH_PORT=' "$CONFIG" | cut -d= -f2)
ACCESS_TIMEOUT=$(grep '^ACCESS_TIMEOUT=' "$CONFIG" | cut -d= -f2)
KNOCK_TIMEOUT=$(grep '^KNOCK_TIMEOUT=' "$CONFIG" | cut -d= -f2)
ACCESS_TIMEOUT=${ACCESS_TIMEOUT:-30}
KNOCK_TIMEOUT=${KNOCK_TIMEOUT:-10}

LOG="/var/log/ssh-knock.log"

log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$LOG"
    logger -t ssh-knock "$1"
}

log "Daemon started. Knock: $KNOCK1 > $KNOCK2 > $KNOCK3, SSH port: $SSH_PORT, Window: ${ACCESS_TIMEOUT}s"

# State tracking: /tmp/ssh-knock-state/<IP> contains stage number and timestamp
STATE_DIR="/tmp/ssh-knock-state"
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"

get_stage() {
    local ip="$1"
    local file="$STATE_DIR/$ip"
    if [ -f "$file" ]; then
        local stage ts now
        read stage ts < "$file"
        now=$(date +%s)
        if [ $((now - ts)) -gt "$KNOCK_TIMEOUT" ] && [ "$stage" -gt 0 ]; then
            rm -f "$file"
            echo 0
        else
            echo "$stage"
        fi
    else
        echo 0
    fi
}

set_stage() {
    local ip="$1" stage="$2"
    if [ "$stage" = "0" ]; then
        rm -f "$STATE_DIR/$ip"
    else
        echo "$stage $(date +%s)" > "$STATE_DIR/$ip"
    fi
}

# Watch for SYN packets to knock ports
# tcpdump captures at raw socket level — sees packets even if CSF drops them
tcpdump -l -n -i any \
    "tcp[tcpflags] & tcp-syn != 0 and tcp[tcpflags] & tcp-ack = 0 and (dst port $KNOCK1 or dst port $KNOCK2 or dst port $KNOCK3)" \
    2>/dev/null | while IFS= read -r line; do

    # Parse tcpdump output: "HH:MM:SS.xxx IP SRC.SRCPORT > DST.DSTPORT: Flags [S]..."
    SRC=$(echo "$line" | grep -oP '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?=\.\d+\s*>)')
    DPORT=$(echo "$line" | grep -oP '(?<=>\s)\S+' | grep -oP '\.(\d+):' | tr -d '.:')

    [ -z "$SRC" ] || [ -z "$DPORT" ] && continue

    STAGE=$(get_stage "$SRC")

    if [ "$STAGE" = "0" ] && [ "$DPORT" = "$KNOCK1" ]; then
        set_stage "$SRC" 1
    elif [ "$STAGE" = "1" ] && [ "$DPORT" = "$KNOCK2" ]; then
        set_stage "$SRC" 2
    elif [ "$STAGE" = "2" ] && [ "$DPORT" = "$KNOCK3" ]; then
        # Knock complete — grant temporary access via CSF
        log "Knock complete from $SRC — granting ${ACCESS_TIMEOUT}s access"
        csf -ta "$SRC" "$ACCESS_TIMEOUT" "ssh-knock" 2>/dev/null
        set_stage "$SRC" 0
    else
        # Wrong sequence — restart if it was knock1, else reset
        if [ "$DPORT" = "$KNOCK1" ]; then
            set_stage "$SRC" 1
        else
            set_stage "$SRC" 0
        fi
    fi
done

log "Daemon stopped unexpectedly"
DAEMONEOF
chmod 755 "$INSTALL_DIR/knock-daemon.sh"
echo -e "${GREEN}OK${NC}"

# Install systemd service
echo -n "Installing systemd service... "
cat > /etc/systemd/system/ssh-knock.service << 'SVCEOF'
[Unit]
Description=SSH Knock - Port Knocking Daemon
After=network.target csf.service lfd.service
Wants=csf.service

[Service]
Type=simple
ExecStart=/opt/ssh-knock/knock-daemon.sh
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable ssh-knock >/dev/null 2>&1
echo -e "${GREEN}OK${NC}"

# Generate client scripts
echo -n "Generating client scripts... "

# Linux client
cat > "$INSTALL_DIR/clients/knock.sh" << 'CLIENTEOF'
#!/bin/bash
# SSH Knock — Linux Client
# Usage: ./knock.sh <hostname> [ssh-user]

HOST="${1}"
SSH_USER="${2:-root}"
SSH_PORT=__SSH_PORT__
PORTS=(__KNOCK1__ __KNOCK2__ __KNOCK3__)

if [ -z "$HOST" ]; then
    echo "SSH Knock — Port Knock Client"
    echo ""
    echo "Usage: ./knock.sh <hostname> [ssh-user]"
    echo "  hostname  Server IP or domain name"
    echo "  ssh-user  SSH username (default: root)"
    echo ""
    echo "Example: ./knock.sh 23.239.105.101 rentalho"
    exit 1
fi

echo "Knocking on $HOST..."

for port in "${PORTS[@]}"; do
    timeout 1 bash -c "echo >/dev/tcp/$HOST/$port" 2>/dev/null || true
    sleep 0.3
done

echo "Knock complete. Connecting..."
sleep 0.5
ssh -p $SSH_PORT ${SSH_USER}@${HOST}
CLIENTEOF

sed -i "s/__SSH_PORT__/$SSH_PORT/g" "$INSTALL_DIR/clients/knock.sh"
sed -i "s/__KNOCK1__/$KNOCK1/g" "$INSTALL_DIR/clients/knock.sh"
sed -i "s/__KNOCK2__/$KNOCK2/g" "$INSTALL_DIR/clients/knock.sh"
sed -i "s/__KNOCK3__/$KNOCK3/g" "$INSTALL_DIR/clients/knock.sh"
chmod 700 "$INSTALL_DIR/clients/knock.sh"

# Windows PowerShell client
cat > "$INSTALL_DIR/clients/knock.ps1" << 'PSEOF'
# SSH Knock — Windows PowerShell Client
# Usage: .\knock.ps1 -HostName <hostname> [-User <ssh-user>]

param(
    [Parameter(Mandatory=$true)]
    [string]$HostName,
    [string]$User = "root"
)

$SSHPort = "__SSH_PORT__"
$Ports = @(__KNOCK1__, __KNOCK2__, __KNOCK3__)

Write-Host "Knocking on $HostName..." -ForegroundColor Cyan

foreach ($port in $Ports) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($HostName, $port, $null, $null)
        $async.AsyncWaitHandle.WaitOne(1000, $false) | Out-Null
        $tcp.Close()
    } catch { }
    Start-Sleep -Milliseconds 300
}

Write-Host "Knock complete. Connecting..." -ForegroundColor Green
Start-Sleep -Seconds 1

if (Get-Command ssh -ErrorAction SilentlyContinue) {
    ssh -p $SSHPort "${User}@${HostName}"
} elseif (Get-Command putty -ErrorAction SilentlyContinue) {
    putty -ssh -P $SSHPort -l $User $HostName
} else {
    Write-Host ""
    Write-Host "SSH port is open for 30 seconds. Connect now:" -ForegroundColor Yellow
    Write-Host "  ssh -p $SSHPort ${User}@${HostName}" -ForegroundColor White
}
PSEOF

sed -i "s/__SSH_PORT__/$SSH_PORT/g" "$INSTALL_DIR/clients/knock.ps1"
sed -i "s/__KNOCK1__/$KNOCK1/g" "$INSTALL_DIR/clients/knock.ps1"
sed -i "s/__KNOCK2__/$KNOCK2/g" "$INSTALL_DIR/clients/knock.ps1"
sed -i "s/__KNOCK3__/$KNOCK3/g" "$INSTALL_DIR/clients/knock.ps1"

# GUI clients — copy from source repo and replace placeholders
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for gui in knock-gui.py knock-gui.ps1; do
    if [ -f "$SCRIPT_DIR/clients/$gui" ]; then
        cp "$SCRIPT_DIR/clients/$gui" "$INSTALL_DIR/clients/$gui"
        sed -i "s/__SSH_PORT__/$SSH_PORT/g" "$INSTALL_DIR/clients/$gui"
        sed -i "s/__KNOCK1__/$KNOCK1/g" "$INSTALL_DIR/clients/$gui"
        sed -i "s/__KNOCK2__/$KNOCK2/g" "$INSTALL_DIR/clients/$gui"
        sed -i "s/__KNOCK3__/$KNOCK3/g" "$INSTALL_DIR/clients/$gui"
        sed -i "s/__HOSTNAME__/$(hostname)/g" "$INSTALL_DIR/clients/$gui"
        chmod 700 "$INSTALL_DIR/clients/$gui"
    fi
done

echo -e "${GREEN}OK${NC}"

# Restart CSF to apply port removal
echo -n "Restarting CSF firewall... "
if ! csf -r > /dev/null 2>&1; then
    echo -e "${RED}FAILED${NC}"
    rollback
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Start the knock daemon
echo -n "Starting knock daemon... "
if ! systemctl start ssh-knock; then
    echo -e "${RED}FAILED${NC}"
    journalctl -u ssh-knock --no-pager -n 5
    rollback
    exit 1
fi
# Give daemon 2 seconds to start tcpdump
sleep 2
if systemctl is-active ssh-knock >/dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED — daemon not running${NC}"
    journalctl -u ssh-knock --no-pager -n 10
    rollback
    exit 1
fi

# Verify CSF port removal
echo -n "Verifying SSH port blocked... "
if grep "^TCP_IN" /etc/csf/csf.conf | grep -q ",${SSH_PORT},\|,${SSH_PORT}\"\|\"${SSH_PORT},"; then
    echo -e "${RED}FAILED — port $SSH_PORT still in TCP_IN${NC}"
    rollback
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Dead man's switch — safety net to restore SSH in 15 minutes
SAFETY_SCRIPT="$INSTALL_DIR/safety-restore.sh"
cat > "$SAFETY_SCRIPT" << 'SAFETYEOF'
#!/bin/bash
# Emergency: restore SSH access and remove all SSH Knock components
systemctl stop ssh-knock 2>/dev/null
systemctl disable ssh-knock 2>/dev/null
rm -f /etc/systemd/system/ssh-knock.service
systemctl daemon-reload 2>/dev/null
if [ -f /opt/ssh-knock/csf.conf.backup ]; then
    cp /opt/ssh-knock/csf.conf.backup /etc/csf/csf.conf
fi
crontab -l 2>/dev/null | grep -v "ssh-knock" | crontab -
csf -r >/dev/null 2>&1
rm -f /opt/ssh-knock/safety-restore.sh
SAFETYEOF
chmod 755 "$SAFETY_SCRIPT"
# Schedule safety restore in 15 minutes
(crontab -l 2>/dev/null | grep -v 'ssh-knock.*safety'; echo "$(date -d '+15 minutes' '+%M %H %d %m *') $SAFETY_SCRIPT # ssh-knock-safety") | crontab -

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!                 ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${RED}>>> SAFETY NET ACTIVE — 15 MINUTES <<<${NC}"
echo -e "${YELLOW}SSH will be restored automatically in 15 minutes if you do not cancel.${NC}"
echo "After testing knock successfully, cancel the safety net:"
echo ""
echo "  crontab -l | grep -v 'ssh-knock.*safety' | crontab -"
echo ""
echo -e "${RED}>>> DO NOT CLOSE THIS SSH SESSION <<<${NC}"
echo ""
echo "Test from another terminal first:"
echo ""
echo -e "${YELLOW}Knock sequence: $KNOCK1 > $KNOCK2 > $KNOCK3${NC}"
echo ""
echo "Quick test (from your local machine):"
echo ""
echo "  # Copy the client script:"
echo "  scp -P $SSH_PORT root@yourserver:$INSTALL_DIR/clients/knock.sh ."
echo "  chmod +x knock.sh"
echo ""
echo "  # Or knock manually:"
echo "  for p in $KNOCK1 $KNOCK2 $KNOCK3; do"
echo "    timeout 1 bash -c \"echo >/dev/tcp/YOURSERVER/\$p\" 2>/dev/null; sleep 0.3"
echo "  done"
echo "  ssh -p $SSH_PORT user@yourserver"
echo ""
echo "Client scripts: $INSTALL_DIR/clients/"
echo "  Linux:     knock.sh <hostname> [user]"
echo "  Windows:   knock.ps1 -HostName <hostname> [-User user]"
echo ""
echo "Config:    $INSTALL_DIR/config"
echo "Uninstall: cd $(pwd) && ./uninstall.sh"
echo ""
echo -e "${YELLOW}Write down your knock sequence and store it safely:${NC}"
echo -e "${GREEN}  $KNOCK1 > $KNOCK2 > $KNOCK3${NC}"
echo ""
