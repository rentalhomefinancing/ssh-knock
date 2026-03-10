# SSH Knock — Code Review TODOs

Reviewed: `install.sh`, `uninstall.sh`, `clients/knock-gui.py`, `clients/knock-gui.ps1`, `ssh-knock.php` (dashboard API)

---

## 1. Shell Scripting Quality (install.sh / uninstall.sh)

- [ ] **`set -e` without `set -o pipefail`** — Piped commands (e.g., `grep | awk` on line 44 of install.sh) will not trigger `set -e` if the left side of the pipe fails. Add `set -euo pipefail` or at minimum `set -eo pipefail`.

- [ ] **Unquoted variable in ss grep** — Line 59: `grep -q ":$port "` is fine, but the `$port` in the arithmetic on line 56 (`port=$((RANDOM % 40000 + 10000))`) is safe. However, `echo $port` on line 63 should be `echo "$port"` (unquoted expansions are a habit that leads to bugs elsewhere).

- [ ] **`source "$INSTALL_DIR/config"` in uninstall.sh is a code injection vector** — Line 32 of uninstall.sh blindly sources the config file. If the config were tampered with (e.g., `SSH_PORT=22; rm -rf /`), it executes arbitrary commands. Use a restricted parser (`grep`/`read` loop) instead of `source`.

- [ ] **`generate_port` uses subshell `$()` — KNOCK1/KNOCK2 not visible inside** — Lines 72-74: `KNOCK1=$(generate_port)` works because the function checks `${KNOCK1:-0}`, but the function runs in a subshell where it sees the *parent's* KNOCK1/KNOCK2. This is actually correct since the variables are set before the next call, but it's subtle and fragile. Adding a comment would help.

- [ ] **`$EUID` is a bashism** — Both scripts use `#!/bin/bash` so this is fine, but the comment says "POSIX compliance" — if portability matters, use `id -u` instead.

- [ ] **No `trap` for cleanup on failure** — If the script fails between removing the SSH port from CSF and adding iptables rules (lines 130-185), the user is locked out with no SSH port allowed and no knock rules active. Add a `trap` that restores `csf.conf` from backup on any non-zero exit.

- [ ] **`csf -r` output silenced completely** — Lines 295-296: If `csf -r` fails, the error is hidden. Capture stderr and display it on failure.

- [ ] **Uninstall runs `read -p` — unusable from PHP API** — The uninstall script prompts for confirmation (line 47), which will hang when called from the dashboard API via `exec('sudo bash ...')`. Add a `-y` / `--yes` flag or detect non-interactive mode (`[[ ! -t 0 ]]`).

---

## 2. iptables Rules Correctness

- [ ] **Knock sequence logic is correct but has a reset gap** — The rules correctly use helper chains (SSH_KNOCK_S2, SSH_KNOCK_S3) to advance the `recent` module state. However, there is no rule to *clear* a failed partial sequence. If a user hits KNOCK1 and KNOCK2 but then sends a wrong port, the KNOCK2 `recent` entry persists until it times out (10 sec). This is minor but means a brute-force attacker gets a free 10-second window on each pair they guess.

- [ ] **No `--remove` of previous stage entries** — When advancing from KNOCK1 to KNOCK2 (line 179), the IP is added to the KNOCK2 list but not removed from KNOCK1. This means the same IP simultaneously exists in KNOCK1 and KNOCK2. An attacker who guesses KNOCK2 could skip stage 1 if they also happen to have a stale KNOCK1 entry. Add `--remove --name KNOCK1` in the SSH_KNOCK_S2 helper chain.

- [ ] **`-m state` is deprecated — use `-m conntrack --ctstate`** — Lines 161, 164, 176: `--state ESTABLISHED,RELATED` works but `xt_state` is legacy. Modern iptables prefers `-m conntrack --ctstate`.

- [ ] **`iptables -I INPUT 1` could conflict with CSF's own INPUT rules** — Line 154 inserts SSH_KNOCK at position 1 in INPUT. CSF restarts (`csf -r`) rebuild all chains via csfpost.sh, so this is correct *after* a restart, but if someone manually runs `csf -r` twice, the chain gets inserted again at position 1 (though the `|| iptables -F` handles the chain already existing). Double-insertion into INPUT is the real risk — add a check: `iptables -C INPUT -j SSH_KNOCK 2>/dev/null || iptables -I INPUT 1 -j SSH_KNOCK`.

- [ ] **No ip6tables rules** — SSH port is removed from TCP6_IN but no ip6tables knock rules are added. IPv6 SSH connections will be silently blocked with no way to knock. Either add parallel ip6tables rules or document that IPv6 SSH is intentionally disabled.

---

## 3. sed Commands — CSF Port Removal

- [ ] **Port substring matching bug (CRITICAL)** — Lines 132-136: The sed pattern `${SSH_PORT}` matches as a *substring*, not a whole word. If `SSH_PORT=22`, the regex will match inside port `2233`, `2222`, `5022`, `22330`, etc., corrupting the TCP_IN list. Fix by using word boundaries: `\b${SSH_PORT}\b` or more portably, anchor on commas/quote boundaries:
  ```bash
  # Correct approach: match port bounded by commas or start/end of value
  sed -i "s/\(${KEY} = \".*\)\b${SSH_PORT}\b,\?/\1/" /etc/csf/csf.conf
  ```
  Or better, use a proper loop: read the value, split on commas, filter out the port, write back.

- [ ] **Multiple sed passes can leave trailing/leading commas** — If the port is at the end, the second sed removes `,PORT` correctly. But if the first sed (trailing comma) matches first on a mid-list port, it could leave `,,` (double comma). The patterns are mutually exclusive for a *single* occurrence, but if the port appears more than once (misconfigured CSF), artifacts remain.

- [ ] **sed modifies ALL lines matching `KEY = "..."` not just the correct one** — If csf.conf has comments containing `TCP_IN = "..."` example lines, sed will modify those too. Safer to match only uncommented lines: `/^TCP_IN/` or `/^[^#]*TCP_IN/`.

---

## 4. Client Scripts (bash knock.sh, PowerShell knock.ps1)

- [ ] **Bash client `echo >/dev/tcp` may not send a clean SYN** — Line 217: `echo >/dev/tcp/$HOST/$port` attempts a full TCP connect via bash's `/dev/tcp` pseudo-device. If the port is DROPped (which it is — line 173), this will hang for the 1-second timeout. The SYN *is* sent, so the `recent` module *will* see it. This works, but the 1-second timeout per knock means the total knock takes ~3.3 seconds minimum. Consider using `nmap --send-ip -Pn --max-retries 0 -p $port` or a raw SYN approach for speed. Not a bug, but a UX concern.

- [ ] **PowerShell client `TcpClient.BeginConnect` — connection may complete** — Lines 250-253 of knock.ps1: If the knock port happens to have a service listening (unlikely but possible), `BeginConnect` could succeed and the `Close()` call happens normally. But the `catch` block is empty, so `Close()` is never called on exception. Use `try/finally { $tcp.Close() }` or `$tcp.Dispose()`.

- [ ] **Bash client uses unquoted `$SSH_PORT` in ssh command** — Line 223: `ssh -p $SSH_PORT` — should be quoted as `ssh -p "$SSH_PORT"` in case of unexpected whitespace.

- [ ] **No input validation on hostname in bash client** — Line 199: `HOST="${1}"` is used directly in `/dev/tcp/$HOST/$port`. A hostname containing spaces or special characters could cause unexpected behavior. Add basic validation.

---

## 5. Python GUI (knock-gui.py)

- [ ] **Placeholders are bare integers — syntax error if not replaced** — Lines 25-26: `KNOCK_SEQ = [__KNOCK1__, __KNOCK2__, __KNOCK3__]` and `SSH_PORT = __SSH_PORT__` will cause a `NameError` at import time if the placeholders are not replaced (e.g., if someone runs the source file directly). Add a guard: check if the values are still strings containing `__` and show an error.

- [ ] **`socket.AF_INET` hardcoded — no IPv6 support** — Line 52: Only creates IPv4 sockets. If the hostname resolves to an IPv6 address, the knock will fail silently. Use `socket.getaddrinfo()` to resolve and pick the right address family.

- [ ] **macOS AppleScript injection** — Lines 83-88: The `ssh_cmd` string is interpolated directly into an AppleScript `do script` command. If the hostname or username contains double quotes, the AppleScript will break or could execute arbitrary commands. Escape the string for AppleScript context.

- [ ] **`subprocess.Popen` without error handling for launched process** — Lines 75, 90, 97: The SSH process is fire-and-forget. If it fails to launch (e.g., bad permissions), the error is silently lost. The function returns `None` (success) even though the terminal may not have opened.

- [ ] **Python 3.6 compatibility is fine** — Uses `object` base class, `format()` strings (not f-strings), `threading`, `tkinter`. No walrus operators or other 3.8+ features. Compatible with 3.6+.

- [ ] **Thread exception handling could leave button disabled** — Lines 246-269: The `finally` block calls `self.root.after(0, self._finish)`, which re-enables the button. This is correct. However, if `self.root` has been destroyed (user closes window during knock), `self.root.after()` will raise `TclError`. Wrap the `finally` in a try/except.

---

## 6. PowerShell GUI (knock-gui.ps1)

- [ ] **Runspace leak — `$ps` and `$runspace` are never disposed** — Lines 174-243: A new `Runspace` and `PowerShell` instance are created on every button click, but `$ps.Dispose()` and `$runspace.Dispose()` are never called. Each click leaks ~2-5MB. Add cleanup in the `finally` block or use `Register-ObjectEvent` on the async result to dispose.

- [ ] **`$ps.BeginInvoke()` result is discarded** — Line 243: The `IAsyncResult` is not stored, so there's no way to call `EndInvoke()` to retrieve errors or clean up. Store it and handle completion.

- [ ] **`[Environment]::Exit(0)` on window close kills entire process abruptly** — Line 247: This skips runspace cleanup, PowerShell disposal, and any pending I/O. Use `$window.Close()` logic or set a cancellation flag and let the script exit naturally.

- [ ] **PowerShell 5.1 compatibility is fine** — Uses `Add-Type` for WPF assemblies, `[RunspaceFactory]`, `[Action]` delegates — all available in PowerShell 5.1+ on Windows. The XAML is also WPF-compatible.

- [ ] **`$Host_` parameter name in `Send-Knock` is a workaround for `$Host` reserved variable** — Line 147: This works but is confusing. Consider renaming to `$TargetHost` for clarity (matching the runspace version which uses `$Target`).

- [ ] **TcpClient not disposed in outer `Send-Knock` function (lines 148-157)** — Same issue as the inner `Send-KnockPacket`: if `BeginConnect` throws synchronously, `$tcp` is never closed. Wrap in `try/finally { if ($tcp) { $tcp.Dispose() } }`.

---

## 7. Config File Format — Injection Risks

- [ ] **`source` in uninstall.sh executes arbitrary code (HIGH SEVERITY)** — As noted in section 1, `source "$INSTALL_DIR/config"` will execute *any* bash code in the config file, not just `KEY=VALUE` assignments. If an attacker gains write access to `/opt/ssh-knock/config` (chmod 600 root-owned, so requires root — but still bad practice), they get arbitrary code execution on next uninstall. Replace with:
  ```bash
  while IFS='=' read -r key val; do
      case "$key" in
          SSH_PORT|KNOCK[123]|*_TIMEOUT) declare "$key=$val" ;;
      esac
  done < "$INSTALL_DIR/config"
  ```

- [ ] **PHP config parser in ssh-knock.php is safe** — Lines 100-106: Uses `explode('=', $line, 2)` and `trim()` — no `eval()` or shell execution of the values. This is correct.

- [ ] **Config values are not validated after reading** — In install.sh, the generated ports are used directly in iptables rules via heredoc expansion. If `KNOCK1` somehow contained shell metacharacters (unlikely from `$((RANDOM ...))` but defensive coding matters), they'd be injected into csfpost.sh. Validate that all port values are numeric before writing csfpost.sh.

---

## 8. Port Generation

- [ ] **`$RANDOM` is 15-bit (0-32767) — reduced entropy** — Line 56: `RANDOM % 40000 + 10000` gives a range of 10000-49999 (40,000 possible values). But `$RANDOM` maxes at 32767, so ports 42768-49999 are *never generated* (32767 % 40000 = 32767, + 10000 = 42767 max). The actual range is 10000-42767. This reduces the keyspace from 40000^3 to 32768^3 (from ~6.4 x 10^13 to ~3.5 x 10^13). Fix: use `$(shuf -i 10000-49999 -n 1)` or read from `/dev/urandom`.

- [ ] **No guarantee generated ports don't conflict with CSF-allowed ports** — The check on line 59 only verifies the port isn't *currently listening*. It doesn't check CSF's `TCP_IN` list. If a generated knock port matches a CSF-allowed port (e.g., 10080 for a web proxy), CSF will accept traffic on that port normally, and the knock packet will be handled by CSF before reaching the SSH_KNOCK chain, potentially breaking the sequence.

- [ ] **`generate_port` fallback on 100 failures returns unchecked port** — Line 67: After 100 failed attempts, it returns a random port without any duplicate or conflict check. This is a safety valve but could return a port equal to SSH_PORT or a duplicate of KNOCK1/KNOCK2.

---

## 9. Dashboard API (ssh-knock.php)

- [ ] **`sudo iptables` and `sudo bash` from PHP — requires passwordless sudo** — Lines 114 and 150: These `exec()` calls require the web server user (e.g., `apache`, `www-data`, `nobody`) to have `NOPASSWD` sudo access for `iptables` and `bash`. If sudoers is not configured, these silently fail. Document the required sudoers entry, and restrict it: `www-data ALL=(root) NOPASSWD: /usr/sbin/iptables -L SSH_KNOCK -n, /bin/bash /opt/ssh-knock/uninstall.sh`.

- [ ] **Uninstall via PHP `exec()` will hang on `read -p` prompt** — As noted in section 1, the uninstall script prompts `read -p "Proceed? [y/N]: "`. When called via `exec()` from PHP with no TTY, `read` will either: (a) read EOF and set CONFIRM to empty, causing the script to echo "Uninstall cancelled" and exit 0, or (b) hang forever depending on how stdin is handled. The API would return `{"success": true, "output": "Uninstall cancelled."}` — **the uninstall silently does nothing and reports success**. Fix: pipe `echo y |` into the script, or add a `--yes` flag.

- [ ] **Error message in catch block leaks internal paths** — Line 128: `$e->getMessage()` could contain filesystem paths or PHP internals. In production, return a generic error and log the details server-side.

- [ ] **Config values exposed to any authenticated user** — Line 108: The full knock sequence (KNOCK1, KNOCK2, KNOCK3) is returned in the GET response. Any authenticated dashboard user can see the knock ports. If the dashboard has multiple user roles, the knock config should be restricted to admins only (currently only uninstall requires `require_admin()`).

- [ ] **No rate limiting on the GET endpoint** — An attacker with valid dashboard credentials (or a session hijack) could poll the API to extract the knock sequence. Minor concern since it requires auth, but worth noting.

- [ ] **Content-Disposition header injection** — Line 72: `$file` is already validated against the whitelist (line 39), so this is safe. No issue here.

---

## 10. General / Cross-Cutting

- [ ] **No log rotation or audit trail** — Neither install nor uninstall log their actions to syslog or a log file. For a security tool, there should be an audit trail of when knock was installed, uninstalled, and what ports were configured.

- [ ] **Knock sequence stored in plaintext in multiple locations** — Config file (`/opt/ssh-knock/config`), csfpost.sh (embedded in iptables rules), all client scripts, and the PHP API response. Consider whether the config file should be the single source of truth with clients fetching dynamically (already possible via the API download endpoint).

- [ ] **No mechanism to rotate the knock sequence** — The only way to change ports is full uninstall + reinstall. A `rotate` command that generates new ports and updates all files atomically would be valuable.

- [ ] **Race condition between CSF config change and rule application** — Lines 130-296 in install.sh: If `csf -r` fails (line 295), the SSH port is already removed from `csf.conf` but no knock rules exist. The rollback on line 304 handles the *verification* failure, but if the script is killed between lines 137 and 295, the server is left with SSH blocked and no knock rules.
