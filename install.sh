#!/bin/bash
# SSH Knock — Port Knocking for CSF Firewalls
# Hides SSH behind a secret 3-port knock sequence
# Run as root

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Rollback function ---
rollback() {
    echo ""
    echo -e "${RED}Rolling back changes...${NC}"
    if [ -f "$INSTALL_DIR/csf.conf.backup" ]; then
        cp "$INSTALL_DIR/csf.conf.backup" /etc/csf/csf.conf
    fi
    if [ -f "$INSTALL_DIR/csfpost.sh.backup" ]; then
        cp "$INSTALL_DIR/csfpost.sh.backup" /etc/csf/csfpost.sh
    elif [ -f /etc/csf/csfpost.sh ]; then
        sed -i '/# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh
    fi
    csf -r > /dev/null 2>&1 || true
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
if grep -q '# === SSH Knock' /etc/csf/csfpost.sh 2>/dev/null; then
    echo -e "${RED}Error: SSH Knock is already installed.${NC}"
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

# Check iptables recent module
if ! modprobe xt_recent 2>/dev/null; then
    echo -e "${RED}Error: iptables 'recent' module not available${NC}"
    exit 1
fi

INSTALL_DIR="/opt/ssh-knock"

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
echo "  1. SSH port $SSH_PORT becomes INVISIBLE to the internet"
echo "  2. Send TCP packets to ports $KNOCK1, $KNOCK2, $KNOCK3 in order"
echo "  3. SSH port opens for YOUR IP only, for 30 seconds"
echo "  4. Your current SSH session will NOT be interrupted"
echo "  5. CSF continues to manage all other firewall rules"
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
if [ -f /etc/csf/csfpost.sh ]; then
    cp /etc/csf/csfpost.sh "$INSTALL_DIR/csfpost.sh.backup"
fi
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

echo -e "${YELLOW}Note: If IPv6 is enabled, verify SSH is also blocked on IPv6. The port was removed from TCP6_IN but additional manual rules may be needed.${NC}"

# Add knock rules to csfpost.sh
echo -n "Adding port knock rules... "

# Make sure csfpost.sh exists, has a shebang, and is executable
if [ ! -f /etc/csf/csfpost.sh ]; then
    echo '#!/bin/bash' > /etc/csf/csfpost.sh
elif ! head -1 /etc/csf/csfpost.sh | grep -q '^#!'; then
    sed -i '1i#!/bin/bash' /etc/csf/csfpost.sh
fi
chmod 755 /etc/csf/csfpost.sh

cat >> /etc/csf/csfpost.sh << KNOCKEOF

# === SSH Knock — Port Knocking Rules ===
# Managed by /opt/ssh-knock — do not edit manually

# Create knock chain
iptables -N SSH_KNOCK 2>/dev/null || iptables -F SSH_KNOCK
iptables -I INPUT 1 -j SSH_KNOCK

# Create helper chains for stage advancement
iptables -N SSH_KNOCK_S2 2>/dev/null || iptables -F SSH_KNOCK_S2
iptables -N SSH_KNOCK_S3 2>/dev/null || iptables -F SSH_KNOCK_S3

# Rule 1: Keep existing SSH sessions alive
iptables -A SSH_KNOCK -p tcp --dport ${SSH_PORT} -m state --state ESTABLISHED,RELATED -j ACCEPT

# Rule 2: Allow SSH from IPs that completed knock (30 sec window)
iptables -A SSH_KNOCK -p tcp --dport ${SSH_PORT} -m state --state NEW -m recent --rcheck --seconds 30 --name KNOCK3 -j ACCEPT

# Rule 3: Third knock — if in KNOCK2, advance to KNOCK3
iptables -A SSH_KNOCK -p tcp --dport ${KNOCK3} -m recent --rcheck --seconds 10 --name KNOCK2 -j SSH_KNOCK_S3

# Rule 4: Second knock — if in KNOCK1, advance to KNOCK2
iptables -A SSH_KNOCK -p tcp --dport ${KNOCK2} -m recent --rcheck --seconds 10 --name KNOCK1 -j SSH_KNOCK_S2

# Rule 5: First knock — start sequence
iptables -A SSH_KNOCK -p tcp --dport ${KNOCK1} -m recent --set --name KNOCK1 -j DROP

# Rule 6: Block all other new SSH connections
iptables -A SSH_KNOCK -p tcp --dport ${SSH_PORT} -m state --state NEW -j DROP

# Helper: advance to stage 2
iptables -A SSH_KNOCK_S2 -m recent --set --name KNOCK2 -j DROP

# Helper: advance to stage 3
iptables -A SSH_KNOCK_S3 -m recent --set --name KNOCK3 -j DROP

# === End SSH Knock ===
KNOCKEOF

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

# Restart CSF to apply rules
echo -n "Restarting CSF firewall... "
if ! csf -r > /dev/null 2>&1; then
    echo -e "${RED}FAILED${NC}"
    rollback
    exit 1
fi
echo -e "${GREEN}OK${NC}"

# Apply knock rules — run csfpost.sh directly (CSF v14/CWP doesn't always auto-execute it)
echo -n "Applying knock rules... "
CSFPOST_ERR=$(bash /etc/csf/csfpost.sh 2>&1)
CSFPOST_RC=$?
if [ $CSFPOST_RC -ne 0 ]; then
    echo -e "${RED}FAILED (exit $CSFPOST_RC):${NC}"
    echo "$CSFPOST_ERR"
    rollback
    exit 1
fi

# Verify rules are in place
if iptables -L SSH_KNOCK -n 2>/dev/null | grep -q "$SSH_PORT"; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED — chain created but rules not matching${NC}"
    echo "  iptables -L SSH_KNOCK output:"
    iptables -L SSH_KNOCK -n 2>&1 | head -10
    rollback
    exit 1
fi

# Install watchdog cron — re-applies rules if CSF restart wipes them
echo -n "Installing watchdog cron... "
WATCHDOG="$INSTALL_DIR/watchdog.sh"
cat > "$WATCHDOG" << 'WDEOF'
#!/bin/bash
# SSH Knock watchdog — re-applies rules if CSF restart wiped them
if ! /usr/sbin/iptables -L SSH_KNOCK -n >/dev/null 2>&1; then
    if [ -f /etc/csf/csfpost.sh ] && grep -q '# === SSH Knock' /etc/csf/csfpost.sh; then
        /bin/bash /etc/csf/csfpost.sh >/dev/null 2>&1
    fi
fi
WDEOF
chmod 755 "$WATCHDOG"
# Add cron entry (every minute)
(crontab -l 2>/dev/null | grep -v 'ssh-knock.*watchdog'; echo "* * * * * $WATCHDOG # ssh-knock-watchdog") | crontab -
echo -e "${GREEN}OK${NC}"

# Dead man's switch — safety net to restore SSH in 15 minutes
SAFETY_SCRIPT="$INSTALL_DIR/safety-restore.sh"
cat > "$SAFETY_SCRIPT" << 'SAFETYEOF'
#!/bin/bash
# Emergency: restore SSH access and remove all SSH Knock components
if [ -f /opt/ssh-knock/csf.conf.backup ]; then
    cp /opt/ssh-knock/csf.conf.backup /etc/csf/csf.conf
fi
sed -i '/# === SSH Knock/,/# === End SSH Knock ===/d' /etc/csf/csfpost.sh 2>/dev/null
# Remove watchdog cron and safety cron
crontab -l 2>/dev/null | grep -v "ssh-knock" | crontab -
# Flush knock chains
iptables -F SSH_KNOCK 2>/dev/null; iptables -F SSH_KNOCK_S2 2>/dev/null; iptables -F SSH_KNOCK_S3 2>/dev/null
iptables -D INPUT -j SSH_KNOCK 2>/dev/null; iptables -X SSH_KNOCK 2>/dev/null
iptables -X SSH_KNOCK_S2 2>/dev/null; iptables -X SSH_KNOCK_S3 2>/dev/null
csf -r >/dev/null 2>&1
rm -f /opt/ssh-knock/safety-restore.sh
SAFETYEOF
chmod 755 "$SAFETY_SCRIPT"
# Schedule safety restore in 15 minutes
(crontab -l 2>/dev/null | grep -v 'ssh-knock.*safety'; echo "$(date -d '+15 minutes' '+%M %H %d %m *') $SAFETY_SCRIPT # ssh-knock-safety") | crontab -

# Verify existing session is still alive (if we got here, it is)
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
