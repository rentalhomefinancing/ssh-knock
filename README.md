# SSH Knock

Port knocking for CSF-managed Linux servers. Hides your SSH port behind a secret 3-port knock sequence.

SSH becomes completely invisible to port scanners. Only someone who knows the knock sequence can open the port, and only for their IP, for 30 seconds.

## How It Works

1. SSH port is blocked by default (removed from CSF allowed ports)
2. User runs the knock client, which sends TCP packets to 3 secret ports in order
3. The server recognizes the sequence and opens SSH for that IP only
4. User has 30 seconds to connect via SSH
5. Once connected, the session stays open. The port re-closes for everyone else
6. Existing SSH sessions are never interrupted

## Architecture

```
Internet --> port scan :22 / :2233 --> BLOCKED (invisible)

Knock client --> :PORT1 :PORT2 :PORT3 --> iptables recognizes sequence
                                              |
                                         Opens SSH for your IP (30 sec)
                                              |
                                         ssh -p 2233 user@server --> CONNECTED
```

No daemons, no extra software. Pure iptables `recent` module rules managed through CSF's `csfpost.sh`.

## Requirements

- Linux server with root access
- CSF (ConfigServer Security & Firewall) installed
- iptables with `xt_recent` module (standard on most kernels)

## Install

```bash
cd /usr/local/src
git clone https://github.com/rentalhomefinancing/ssh-knock.git
cd ssh-knock
chmod +x install.sh
./install.sh
```

The installer:
- Detects your SSH port
- Generates a random 3-port knock sequence
- Configures CSF and iptables rules
- Creates ready-to-use client scripts for Linux and Windows

**Keep your SSH session open after install.** Test the knock from another terminal first.

## Client Scripts

After install, client scripts with your knock sequence baked in are saved to `/opt/ssh-knock/clients/`.

### Linux

```bash
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock.sh .
chmod +x knock.sh

# Use it
./knock.sh yourserver.com root
```

### Windows (PowerShell)

```powershell
# Copy from server
scp -P 2233 root@yourserver:/opt/ssh-knock/clients/knock.ps1 .

# Use it
.\knock.ps1 -HostName yourserver.com -User root
```

Both clients knock then automatically SSH in.

## Manual Knock (no client needed)

```bash
# Linux/Mac — replace ports with your sequence
for p in PORT1 PORT2 PORT3; do
  timeout 1 bash -c "echo >/dev/tcp/yourserver/$p" 2>/dev/null; sleep 0.3
done
ssh -p 2233 root@yourserver
```

## Uninstall

```bash
cd /usr/local/src/ssh-knock
./uninstall.sh
```

Restores CSF config from backup, removes knock rules, reopens SSH port normally.

## Configuration

Config is saved at `/opt/ssh-knock/config` after install:

```
SSH_PORT=2233
KNOCK1=17291
KNOCK2=24518
KNOCK3=38103
KNOCK_TIMEOUT=10
ACCESS_TIMEOUT=30
```

To change the knock sequence, uninstall and reinstall.

## What Install Changes

| Change | Reversible |
|--------|-----------|
| Removes SSH port from CSF `TCP_IN` | Yes - backup at `/opt/ssh-knock/csf.conf.backup` |
| Adds iptables rules to `/etc/csf/csfpost.sh` | Yes - backup at `/opt/ssh-knock/csfpost.sh.backup` |
| Creates `/opt/ssh-knock/` with config and client scripts | Yes - removed on uninstall |

## Security Notes

- The knock sequence acts like a password. Keep it secret.
- Each knock must arrive within 10 seconds of the previous one.
- After a successful knock, SSH opens for that IP only for 30 seconds.
- Once connected, your session stays open indefinitely (standard SSH behavior).
- Port knocking is defense-in-depth. It doesn't replace SSH key auth or strong passwords, it adds a layer that makes SSH invisible to scanners and automated exploits.

## Credits

Built by [Rental Home Financing](https://rentalhomefinancing.com) with [Claude Code](https://claude.ai/claude-code) by Anthropic.

## License

MIT
