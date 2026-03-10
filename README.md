# SSH Knock

Port knocking for CSF-managed Linux servers. Hides your SSH port behind a secret 3-port knock sequence.

SSH becomes invisible to port scanners. Only someone who knows the knock sequence can open the port — and only for their IP, for 30 seconds.

## How It Works

1. SSH port is removed from CSF allowed ports (invisible to the outside world)
2. A lightweight daemon watches for TCP SYN packets via `tcpdump`
3. User sends TCP packets to 3 secret ports in the correct order
4. The daemon detects the sequence and runs `csf -ta` to temporarily allow that IP
5. User has 30 seconds to connect via SSH
6. Once connected, the session stays open. The port re-closes for everyone else
7. Existing SSH sessions are never interrupted

## Architecture

```
Internet --> port scan :22 / :2233 --> BLOCKED (invisible)

Knock client --> :PORT1 :PORT2 :PORT3 --> Daemon (tcpdump) detects sequence
                                               |
                                          csf -ta (temp allow your IP, 30s)
                                               |
                                          ssh -p 2233 user@server --> CONNECTED
```

The daemon uses `tcpdump` to watch for SYN packets on the knock ports and CSF's native `csf -ta` (temporary allow) to open SSH. Zero custom iptables rules — CSF manages everything.

## Requirements

- Linux server with root access
- CSF (ConfigServer Security & Firewall) installed
- `tcpdump` (installed on most systems, or `yum install tcpdump`)
- Python 3 (for the port-removal step during install)

## Install

```bash
cd /usr/local/src
git clone https://github.com/rentalhomefinancing/ssh-knock.git
cd ssh-knock
chmod +x install.sh
./install.sh
```

The installer will:
- Detect your SSH port from `sshd_config`
- Generate a random 3-port knock sequence (ports 10000–49999)
- Remove your SSH port from CSF `TCP_IN` / `TCP6_IN`
- Install and start the knock daemon as a systemd service
- Generate ready-to-use client scripts (CLI + GUI) for Linux, macOS, and Windows
- Set a **15-minute safety net** that auto-restores SSH if you get locked out

**Keep your SSH session open after install.** Test the knock from another terminal first.

### Cancel the Safety Net

After you've verified the knock works, remove the safety timer:

```bash
crontab -l | grep -v 'ssh-knock.*safety' | crontab -
```

If you don't cancel it, SSH access is automatically restored in 15 minutes (the knock will stop working).

## Client Scripts

After install, client scripts with your knock sequence baked in are saved to `/opt/ssh-knock/clients/`. Copy them to your local machine and use them to connect.

### Linux / macOS (CLI)

```bash
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock.sh .
chmod +x knock.sh

# Use it
./knock.sh yourserver.com root
```

Sends the knock sequence using bash's `/dev/tcp` pseudo-device, waits briefly, then SSHs in automatically.

### Windows (PowerShell CLI)

```powershell
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock.ps1 .

# Use it
.\knock.ps1 -HostName yourserver.com -User root
```

Uses `TcpClient` for knocking. Tries OpenSSH first, falls back to PuTTY if available.

### Cross-Platform GUI (Python / tkinter)

```bash
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock-gui.py .

# Run it (requires Python 3 + tkinter)
python3 knock-gui.py
```

Dark-themed GUI with hostname/user fields, progress feedback, and automatic terminal launch. Works on Linux, macOS, and Windows.

**tkinter install** (if not already present):
- Debian/Ubuntu: `sudo apt install python3-tk`
- Fedora/RHEL: `sudo dnf install python3-tkinter`
- macOS: `brew install python-tk`
- Windows: included with standard Python install

### Windows GUI (PowerShell / WPF)

```powershell
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock-gui.ps1 .

# Run it
powershell -ExecutionPolicy Bypass -File knock-gui.ps1
```

Native Windows WPF app with dark theme, progress bar, and keyboard shortcuts (Enter to knock, Escape to close). Requires PowerShell 5.1+ (built into Windows 10/11).

### Manual Knock (no client needed)

If you don't have a client script handy:

```bash
# Linux/Mac — replace PORT1 PORT2 PORT3 with your sequence
for p in PORT1 PORT2 PORT3; do
  timeout 1 bash -c "echo >/dev/tcp/yourserver/$p" 2>/dev/null; sleep 0.3
done
ssh -p 2233 root@yourserver
```

## CWP Module (Optional)

If your server runs CWP (Control Web Panel), you can install an admin panel module for managing SSH Knock from the browser.

### What It Does

- **Status dashboard** — see daemon status, current knock sequence, SSH port at a glance
- **Daemon controls** — start / stop / restart the knock daemon
- **Port regeneration** — generate a new random knock sequence with one click (includes a 15-minute safety revert)
- **Client downloads** — download all 4 client scripts directly from the CWP panel (knock sequence pre-configured)
- **Logs** — view daemon log, systemd journal, and audit log in tabbed interface

### Install the CWP Module

SSH Knock must already be installed (`./install.sh`) before adding the CWP module.

```bash
cd /usr/local/src/ssh-knock/cwp-module
chmod +x install-cwp-module.sh
./install-cwp-module.sh
```

Access it at: `https://yourserver:2031/index.php?module=ssh_knock`

The module appears in the CWP admin sidebar under **SSH Knock** (lock icon).

### Uninstall the CWP Module

Removes only the CWP panel — does NOT affect the knock daemon or SSH protection.

```bash
/opt/ssh-knock/uninstall-cwp-module.sh
```

## Uninstall

Completely removes SSH Knock and restores normal SSH access:

```bash
cd /usr/local/src/ssh-knock
./uninstall.sh
```

If you have the CWP module installed, uninstall it first:

```bash
/opt/ssh-knock/uninstall-cwp-module.sh
./uninstall.sh
```

Pass `--yes` to skip the confirmation prompt:

```bash
./uninstall.sh --yes
```

The uninstaller:
- Stops and removes the knock daemon service
- Re-adds your SSH port to CSF `TCP_IN` / `TCP6_IN`
- Removes temporary CSF allows
- Cleans up legacy `csfpost.sh` rules (from older installs)
- Restarts CSF
- Removes `/opt/ssh-knock/`

## Configuration

Config lives at `/opt/ssh-knock/config` after install:

```
SSH_PORT=2233
KNOCK1=17291
KNOCK2=24518
KNOCK3=38103
KNOCK_TIMEOUT=10
ACCESS_TIMEOUT=30
```

| Setting | Default | Description |
|---------|---------|-------------|
| `SSH_PORT` | auto-detected | SSH port to protect |
| `KNOCK1/2/3` | random | The 3-port knock sequence |
| `KNOCK_TIMEOUT` | 10 | Max seconds between each knock |
| `ACCESS_TIMEOUT` | 30 | Seconds SSH stays open after successful knock |

**To change the knock sequence:**
- With CWP module: click **Regenerate Ports** in the admin panel
- Without CWP module: uninstall and reinstall

## What Install Changes

| Change | Reversible |
|--------|-----------|
| Removes SSH port from CSF `TCP_IN` / `TCP6_IN` | Yes — backup at `/opt/ssh-knock/csf.conf.backup` |
| Installs systemd service `ssh-knock` | Yes — removed on uninstall |
| Creates `/opt/ssh-knock/` (config, daemon, clients) | Yes — removed on uninstall |
| Writes daemon log to `/var/log/ssh-knock.log` | Yes — removed on uninstall |

## Server File Layout

```
/opt/ssh-knock/
├── config                    # Knock sequence and settings
├── knock-daemon.sh           # Daemon (tcpdump + csf -ta)
├── csf.conf.backup           # Pre-install CSF backup
├── clients/
│   ├── knock.sh              # Linux/macOS CLI client
│   ├── knock.ps1             # Windows PowerShell CLI client
│   ├── knock-gui.py          # Cross-platform Python GUI
│   └── knock-gui.ps1         # Windows WPF GUI
├── templates/                # Client templates (for port regeneration)
├── backups/                  # CWP module backups
├── regenerate-ports.sh       # Port rotation script (CWP module)
└── audit.log                 # Action audit trail

/etc/systemd/system/ssh-knock.service   # Systemd unit
/var/log/ssh-knock.log                  # Daemon activity log
/etc/logrotate.d/ssh-knock              # Log rotation (CWP module)
```

## Security Notes

- The knock sequence acts like a password. Keep it secret.
- Each knock must arrive within 10 seconds of the previous one.
- After a successful knock, SSH opens for that IP only, for 30 seconds.
- Once connected, your session stays open indefinitely (standard SSH behavior).
- The daemon runs as a systemd service with auto-restart on failure.
- Port knocking is **defense-in-depth**. It doesn't replace SSH key auth or strong passwords — it adds a layer that makes SSH invisible to scanners and automated exploits.

## Credits

Built by [Rental Home Financing](https://rentalhomefinancing.com) with [Claude Code](https://claude.ai/claude-code) by Anthropic.

## License

MIT
