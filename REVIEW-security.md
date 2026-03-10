# SSH Knock — Security Review

Ruthless devil's advocate audit of install.sh, uninstall.sh, and all client scripts.

---

## CRITICAL (will break things or create vulnerabilities)

- [ ] **No dead man's switch / emergency access path** — If the knock rules fail silently (e.g., `xt_recent` module unloads after kernel update, `/proc/net/xt_recent/` fills up, or csfpost.sh has a syntax error), the SSH port is permanently blocked with zero way back in except console/IPMI/KVM access. Add a cron-based dead man's switch: e.g., a cron job that runs every 15 minutes and, if a flag file (e.g., `/tmp/ssh-knock-alive`) hasn't been touched recently, temporarily opens the SSH port for 5 minutes. Or at minimum, add a CSF `ALLOW` for a specific "rescue" IP.

- [ ] **Running `csf -r` with rules already broken is catastrophic on rollback** — In the install.sh rollback path (line 304-314), if iptables rules failed to apply, the script restores csf.conf and calls `csf -r` again. But if CSF itself is broken (e.g., csfpost.sh has a syntax error from a partial write), the second `csf -r` also fails, and the user is locked out with SSH port removed from TCP_IN and no working knock rules. The rollback should validate csfpost.sh syntax before restarting CSF, or restore the csfpost.sh backup first (currently it only does so conditionally).

- [ ] **`set -e` + failed `csf -r` = silent partial install** — `install.sh` uses `set -e`. If `csf -r` on line 295 fails (non-zero exit), the script aborts immediately and never reaches the verification/rollback logic on lines 299-315. The user is left with SSH removed from TCP_IN, knock rules appended to csfpost.sh but not activated, and no way in. Either trap EXIT for cleanup, or wrap the `csf -r` call so `set -e` doesn't kill the script before rollback runs.

- [ ] **sed commands for TCP_IN removal are fragile and can corrupt CSF config** — The sed patterns on lines 130-137 use greedy `.*` inside the capture groups, which can match across multiple ports incorrectly. Example: if `TCP_IN = "20,22,2233,80"` and SSH_PORT=22, the first sed (`${SSH_PORT},`) would also match `2233,` because `22` appears inside `2233`. The sed needs word-boundary matching or anchor to the comma delimiter. Fix: use a more precise regex that matches `,22,` or `"22,` or `,22"` specifically, such as using perl or a more careful sed with explicit comma/quote boundaries.

- [ ] **Re-running install.sh appends duplicate rules to csfpost.sh** — The install uses `cat >>` (append) to csfpost.sh. If install.sh is run twice (e.g., user forgot they installed it, or first run appeared to fail), csfpost.sh gets duplicate knock blocks. On `csf -r`, iptables will try to create SSH_KNOCK chain twice, the `2>/dev/null || iptables -F SSH_KNOCK` handles the chain, but `iptables -I INPUT 1 -j SSH_KNOCK` runs twice, inserting two jump rules into INPUT. This creates undefined behavior and makes uninstall incomplete (sed only removes one block if markers are duplicated). Add an idempotency check at the top of install.sh.

- [ ] **Knock sequence stored in plaintext in client scripts distributed to users** — The client scripts (`knock.sh`, `knock.ps1`, GUI clients) contain the knock ports in plaintext. Anyone who obtains a client file learns the full knock sequence. This is inherent to the design, but the README should be much more explicit about this risk, and the config file permissions (600) should extend to the client scripts too. Currently `knock.sh` is chmod 755 (world-readable). At minimum make them 700.

## HIGH (significant issues)

- [ ] **Uninstall restores entire csf.conf from backup, overwriting any changes made since install** — If the admin added new firewall rules, IP allows, or port changes to csf.conf after SSH Knock was installed, uninstall.sh (line 58) blindly restores the backup copy, wiping all those changes. The uninstall should only re-add the SSH port to TCP_IN/TCP6_IN, not replace the entire file.

- [ ] **xt_recent module has a default table size of 100 entries** — The kernel's xt_recent module defaults to `ip_list_tot=100`. After 100 unique IPs attempt the first knock, the oldest entries get evicted. On a server facing moderate internet traffic (scanners hitting random ports including KNOCK1), the KNOCK1 recent list fills up fast, and legitimate knock attempts get evicted before completing the sequence. Fix: document that `/sys/module/xt_recent/parameters/ip_list_tot` should be increased (e.g., `modprobe xt_recent ip_list_tot=1000`), or better, set it during install.

- [ ] **No IPv6 support — server is exposed on IPv6** — The installer only manipulates IPv4 iptables. If the server has IPv6 connectivity, SSH port remains wide open on IPv6. The csfpost.sh rules use `iptables` only, not `ip6tables`. Either add parallel ip6tables rules, or explicitly document that IPv6 must be disabled or blocked separately.

- [ ] **CSF `PORTS_FLOOD` / `PORTFLOOD` can interfere with knock sequence** — CSF's connection flood protection may rate-limit or block the rapid successive connections to knock ports, treating them as a port scan or flood. If CSF's `PORTFLOOD` or `CT_LIMIT` triggers, the knock SYN packets get dropped before reaching the xt_recent rules. The installer should check and warn about these settings.

- [ ] **CSF `LF_SPI` (Stateful Packet Inspection) and `DENY_IP_LIMIT` interactions** — CSF's default SPI rules may interfere with the knock chain ordering. Since SSH_KNOCK is inserted at INPUT position 1, it should run before CSF's own rules, but if CSF has connection tracking rules that drop unmatched SYN packets before they reach the INPUT chain processing, the knocks never register. Need to verify CSF rule ordering after restart.

- [ ] **`source "$INSTALL_DIR/config"` in uninstall is unsafe** — The uninstall script (line 32) sources the config file. If the config file is maliciously modified (e.g., by another user with write access to /opt/ssh-knock/), arbitrary commands execute as root. Although the directory should be root-owned, the script doesn't verify ownership/permissions before sourcing. Add a check that the file is owned by root and permissions are 600.

- [ ] **PowerShell knock.ps1 SSH port is a string, not an integer** — Line 243 of install.sh template: `$SSHPort = "__SSH_PORT__"` — the port is stored as a string in quotes. While PowerShell handles this implicitly in most contexts, `ssh -p "$SSHPort"` behaves differently than `ssh -p 2233`. Minor, but inconsistent with the GUI script which uses `$sshPort = __SSH_PORT__` (integer).

## MEDIUM (should fix)

- [ ] **No validation of user-supplied SSH port** — Line 48-49: the user can type anything (letters, negative numbers, port 0, port 99999) and the script proceeds. Add validation that SSH_PORT is a number between 1-65535, and that it actually matches a running sshd.

- [ ] **`RANDOM` is only 15-bit (0-32767) so `RANDOM % 40000` is biased** — The generated knock ports cluster in range 10000-42767 with a non-uniform distribution. More importantly, `$RANDOM` in bash is seeded from PID and time, making the ports somewhat predictable if the attacker knows the approximate install time. Use `/dev/urandom` for better entropy: `port=$(shuf -i 10000-49999 -n 1)`.

- [ ] **Knock port collision with CSF allowed ports not checked** — The generated knock ports are checked against `ss -tlnp` (listening ports), but not against CSF's TCP_IN allowed list. If a knock port happens to match a CSF-allowed port (e.g., 10000 if Webmin is on that port), CSF will ACCEPT connections on that port before the knock chain processes them, and the knock may not register in xt_recent.

- [ ] **Race condition: SSH port removed from CSF before knock rules are active** — Between line 137 (SSH port removed from csf.conf) and line 296 (`csf -r` completes), there's a window where the config is modified but not yet applied. If the script crashes in between, SSH port is removed from the config file but knock rules aren't in csfpost.sh yet (or aren't applied). Next CSF restart = lockout.

- [ ] **`timeout 1 bash -c "echo >/dev/tcp/$HOST/$port"` knock method is unreliable** — The Linux client uses bash's `/dev/tcp` pseudo-device, which attempts a full TCP connect. If the port DROPs (as the iptables rules do), the connect hangs for the full 1-second timeout. With 0.3s sleep between knocks, the total knock time is ~3.9s (3x1s timeout + 2x0.3s sleep). If network latency varies, the 10-second inter-knock timeout should be fine, but the user experience is slow. Consider using `nmap --host-timeout` or raw SYN with `hping3` where available.

- [ ] **csfpost.sh backup doesn't handle the case where csfpost.sh was created between backup and rule insertion** — Line 121-123 backs up csfpost.sh only if it exists. Line 144 creates it with `touch` if it doesn't exist. If install fails and rollback runs, it restores the backup (which doesn't exist) or tries sed removal. But if csfpost.sh didn't exist before and the rollback path on line 307 checks for the backup, it won't find one, and falls through to sed — which should work. This is actually handled, but edge-case: if another process creates csfpost.sh between the backup check and the touch, the backup is stale.

- [ ] **Uninstall flushes chains AFTER `csf -r`** — Lines 78-85 of uninstall.sh flush and delete the SSH_KNOCK chains after CSF restart. But `csf -r` runs csfpost.sh, which recreates the chains (since the sed removal on line 69 already removed them from csfpost.sh... but only if that sed ran correctly). If the sed removal failed (e.g., markers were corrupted), `csf -r` re-applies the knock rules, and then the flush on lines 79-85 removes them, leaving a dangling INPUT jump to a deleted chain. Should verify csfpost.sh is clean before restarting CSF.

- [ ] **Client scripts use `-o StrictHostKeyChecking=no`** — The Python GUI client (line 64) passes `-o StrictHostKeyChecking=no` to SSH. This disables host key verification, making the connection vulnerable to MITM attacks. Remove this flag and let the user manage known_hosts normally.

- [ ] **Python GUI `launch_ssh` is vulnerable to command injection** — Line 64: `ssh_cmd` is built with string formatting from user-supplied `host` and `user` fields. If a user types `; rm -rf /` in the hostname field, it gets embedded in the command string passed to `subprocess.Popen` via shell. The gnome-terminal path (line 71) passes it through `bash -c`, enabling injection. Use `shlex.quote()` or pass arguments as a list.

- [ ] **No log of knock attempts for intrusion detection** — Successful and failed knock attempts are invisible. There's no logging of partial sequences or completed knocks. Add iptables LOG rules (rate-limited) for at least successful knock completions, so the admin can audit access.

## LOW (nice to have)

- [ ] **`hostname` embedded in GUI clients may resolve to `localhost`** — Line 286 of install.sh uses `$(hostname)` to replace `__HOSTNAME__` in GUI clients. On many servers, `hostname` returns the short hostname (e.g., `server1`), not the public IP or FQDN. Users would need to manually change the hostname field in the GUI. Consider using the server's public IP instead (e.g., from `curl -s ifconfig.me`).

- [ ] **No integrity check on config or csfpost.sh rules** — After install, there's no way to verify the knock rules haven't been tampered with. A checksum/hash of the csfpost.sh knock block stored in the config would allow periodic verification.

- [ ] **Client scripts don't verify knock succeeded before connecting** — The clients blindly send knocks then connect. If a knock fails (e.g., packet dropped by intermediate firewall), the SSH connection attempt fails with a generic timeout. Adding a quick port-open check (e.g., `nc -z -w2 host SSH_PORT`) between knock and connect would give users better feedback.

- [ ] **Uninstall doesn't clean up xt_recent entries** — After uninstall, `/proc/net/xt_recent/KNOCK1`, `KNOCK2`, `KNOCK3` files may persist until the module is unloaded. Not a functional issue but leaves artifacts.

- [ ] **No backup of the original `/opt/ssh-knock` on reinstall** — If the user runs install.sh again without uninstalling, the existing config (with the old knock sequence) is silently overwritten. The old knock sequence is lost forever if not recorded elsewhere.

- [ ] **PowerShell GUI leaks runspace on each click** — In `knock-gui.ps1`, each button click (line 174) creates a new runspace that is never disposed. If the user clicks multiple times, runspaces accumulate. Use a single background runspace or dispose after completion.

- [ ] **No timeout/retry guidance for users** — If a knock sequence fails (network hiccup, packet loss), there's no guidance on whether to retry immediately or wait. Since xt_recent tracks by IP, a failed partial sequence may leave stale state that interferes with the next attempt (e.g., KNOCK1 is set, user retries and hits KNOCK1 again, which resets the timer but the KNOCK2 state from the first attempt is stale).

- [ ] **`generate_port` fallback on line 67 can return duplicates or the SSH port** — After 100 failed attempts, it falls back to an unchecked random port. This could collide with KNOCK1, KNOCK2, or SSH_PORT. The fallback should still enforce uniqueness.

- [ ] **README claims "no daemons, no extra software" but requires `xt_recent` kernel module** — Pedantic, but `xt_recent` must be loaded (and may not be on minimal/container kernels). The installer checks for it but the marketing claim is slightly misleading.

- [ ] **Windows GUI `[Environment]::Exit(0)` on window close kills the entire PowerShell host** — Line 247 of knock-gui.ps1. If the script was launched from an existing PowerShell session (not double-clicked), closing the GUI window terminates the parent session. Use `$window.Close()` or set a flag to exit the dialog loop cleanly.
