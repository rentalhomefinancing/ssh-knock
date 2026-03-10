# SSH Knock — Reversibility Audit

Audited: 2026-03-10
Files reviewed: `install.sh`, `uninstall.sh`

---

## Files Modified by Install

### 1. `/etc/csf/csf.conf` — SSH port removed from TCP_IN and TCP6_IN

**Install does:** Backs up to `/opt/ssh-knock/csf.conf.backup`, then uses `sed` to remove `$SSH_PORT` from `TCP_IN` and `TCP6_IN` comma-separated lists (lines 119-137).

**Uninstall does:** Restores the entire file from `/opt/ssh-knock/csf.conf.backup` (line 57-58).

**Complete? YES** — Full file restore from backup is the correct approach. It restores the exact original, including any other CSF settings that may have been in place. If the backup file is missing, it warns the user but does NOT attempt to re-add the port programmatically, which is acceptable degraded behavior.

**Caveat:** If the user (or CSF, or another tool) modified `csf.conf` AFTER ssh-knock was installed, those changes will be lost when the backup is restored. This is an inherent limitation of backup-restore and is acceptable — but could be documented.

---

### 2. `/etc/csf/csfpost.sh` — Knock rules appended

**Install does:**
- `touch /etc/csf/csfpost.sh` (creates if missing) and `chmod 755` (line 144-145)
- Appends a block delimited by `# === SSH Knock — Port Knocking Rules ===` ... `# === End SSH Knock ===` (lines 147-185)
- Backs up the original to `/opt/ssh-knock/csfpost.sh.backup` IF the file existed before install (lines 121-123)

**Uninstall does:**
- If backup exists: restores entire file from backup (line 67)
- If no backup: uses `sed` to delete from `# === SSH Knock` to `# === End SSH Knock ===` (line 69)

**Complete? NO — Two issues:**

**Issue A — File created by install is not cleaned up when it didn't exist before.**
If `csfpost.sh` did NOT exist before install, no backup is created (line 121-123 — the `if` guard). The install then creates the file via `touch` (line 144). On uninstall, since there's no backup, the `sed` path runs, which removes the knock block but leaves behind an empty (or near-empty) file. The file should be removed entirely if it didn't exist before install, restoring the system to the exact prior state.

**Issue B — `chmod 755` on pre-existing file not reversed.**
If `csfpost.sh` existed before install but had different permissions, `chmod 755` (line 145) may change them. The backup is a content-only copy (`cp`), so restoring from backup restores content but the permissions set by install persist. In practice, `csfpost.sh` should always be 755 for CSF to execute it, so this is low-risk but technically not a perfect reversal.

**Issue C — Blank line before the block.**
The `cat >>` heredoc (line 147) inserts a leading blank line before `# === SSH Knock`. The `sed` deletion pattern `/# === SSH Knock/,/# === End SSH Knock ===/d` does NOT remove that leading blank line. When the sed fallback path is used (no backup), a stray blank line is left in the file. Minor but not zero-trace.

---

### 3. `/opt/ssh-knock/` directory — Created by install

**Install does:** `mkdir -p /opt/ssh-knock/clients` (line 103). Populates with: `config`, `csf.conf.backup`, `csfpost.sh.backup` (conditional), `clients/knock.sh`, `clients/knock.ps1`, `clients/knock-gui.py` (conditional), `clients/knock-gui.ps1` (conditional).

**Uninstall does:** `rm -rf /opt/ssh-knock` (line 89).

**Complete? YES** — Full recursive removal covers everything.

---

### 4. iptables chains (SSH_KNOCK, SSH_KNOCK_S2, SSH_KNOCK_S3)

**Install does:** Chains are created by the rules appended to `csfpost.sh`, which run when `csf -r` is called (line 295). The chains are: `SSH_KNOCK`, `SSH_KNOCK_S2`, `SSH_KNOCK_S3`. An `INPUT` jump rule (`iptables -I INPUT 1 -j SSH_KNOCK`) is also added.

**Uninstall does:**
1. Restores `csfpost.sh` (removes the rules from future CSF restarts) and runs `csf -r` (line 75) — this means CSF rebuilds its chains WITHOUT the knock rules.
2. Then explicitly flushes and deletes the chains (lines 79-85): flush SSH_KNOCK, SSH_KNOCK_S2, SSH_KNOCK_S3; delete INPUT jump; delete all three chains.

**Complete? YES — but with a redundancy note.** The `csf -r` on line 75 rebuilds iptables from scratch, which should already remove these chains (since the rules are no longer in `csfpost.sh`). The explicit flush/delete on lines 79-85 is a belt-and-suspenders approach, which is good defensive coding. However, there's a subtle issue: if `csf -r` fully rebuilds iptables (which it does — CSF flushes all chains and rebuilds), the explicit cleanup on lines 79-85 will likely encounter "chain doesn't exist" errors, which are silently swallowed by `|| true`. This is fine.

**Potential gap:** The `iptables -D INPUT -j SSH_KNOCK` on line 82 only removes ONE matching rule from INPUT. If `csf -r` was run multiple times while ssh-knock was installed (e.g., user manually ran `csf -r`), and CSF re-executes `csfpost.sh` each time, only ONE `iptables -I INPUT 1 -j SSH_KNOCK` insert happens per restart (the chain is flushed first via `|| iptables -F SSH_KNOCK`). So there should only ever be one INPUT jump rule. This is correct.

---

### 5. Cron entries

**Install does:** No cron entries are added.

**Uninstall does:** N/A.

**Complete? YES** — Nothing to reverse.

---

### 6. Kernel module `xt_recent`

**Install does:** `modprobe xt_recent` (line 36) — loads the kernel module as a prerequisite check.

**Uninstall does:** Does NOT unload the module.

**Complete? ACCEPTABLE** — Unloading `xt_recent` via `modprobe -r xt_recent` could break other iptables rules that use the `recent` module, and it may have been loaded before install anyway. Not unloading is the correct choice. The module will be unloaded on next reboot if nothing else uses it.

---

### 7. Temp files

**Install does:** No explicit temp files. All file operations write directly to `/opt/ssh-knock/` or `/etc/csf/`.

**Uninstall does:** N/A.

**Complete? YES** — Nothing to clean up.

---

### 8. `/etc/ssh/sshd_config` — Read only

**Install does:** Reads `Port` directive to detect SSH port (line 44). Does NOT modify the file.

**Uninstall does:** N/A.

**Complete? YES** — No modification to reverse.

---

### 9. `/proc/net/xt_recent/*` — Kernel recent match tables

**Install does:** The iptables rules create kernel-managed recent match tables: `KNOCK1`, `KNOCK2`, `KNOCK3` (in `/proc/net/xt_recent/`). These are created automatically by iptables when the `--name` flag is used.

**Uninstall does:** When chains are flushed and deleted, and the `xt_recent` rules are removed, the kernel cleans up these entries automatically.

**Complete? YES** — Kernel handles cleanup when the referencing iptables rules are removed.

---

## TODO List

- [ ] **csfpost.sh created but never removed when it didn't exist before install.** If `/etc/csf/csfpost.sh` did not exist prior to install, the install creates it (via `touch` on line 144). On uninstall, no backup exists, so the `sed` fallback runs, leaving an empty file behind. **Fix:** During install, record whether csfpost.sh existed (e.g., write a flag like `CSFPOST_EXISTED=false` to the config file). On uninstall, if the flag is false and the sed fallback path is taken, `rm /etc/csf/csfpost.sh` instead of sed-editing it.

- [ ] **Stray blank line left by sed fallback in csfpost.sh.** The heredoc appended to `csfpost.sh` starts with a blank line (line 148 is empty). The sed pattern `/# === SSH Knock/,/# === End SSH Knock ===/d` does not capture that preceding blank line. **Fix:** Either (a) change the sed pattern to also match the blank line before the marker, e.g., `/^$/,/# === End SSH Knock ===/{ /^$/{ N; /# === SSH Knock/d }; /# === SSH Knock/,/# === End SSH Knock ===/d }` — or more simply (b) don't emit the leading blank line in the heredoc during install (remove the empty line after `KNOCKEOF` on line 147).

- [ ] **Post-install CSF config drift not documented.** If the user or CSF modifies `csf.conf` after ssh-knock is installed (e.g., opening new ports, changing settings), the uninstall will overwrite those changes by restoring the pre-install backup. This is a fundamental limitation of the backup-restore approach. **Fix:** Document this in the README and/or print a warning during uninstall: "Warning: Restoring csf.conf from backup taken at install time. Any CSF changes made after install will be reverted."

- [ ] **csfpost.sh permissions not preserved.** Install runs `chmod 755` on `csfpost.sh` (line 145). If the file had different permissions before (unlikely but possible), those permissions are not recorded or restored. The backup via `cp` does not preserve permissions by default (it uses the umask). **Fix:** Use `cp -p` when backing up csfpost.sh (line 122) to preserve permissions, or record and restore permissions explicitly. Low priority since 755 is the expected value.

- [ ] **No ip6tables cleanup in uninstall.** Install removes the SSH port from `TCP6_IN` in `csf.conf` (line 130-137), which affects IPv6. The `csf -r` restart handles rebuilding ip6tables rules from config. However, the explicit chain cleanup in uninstall (lines 79-85) only targets `iptables`, not `ip6tables`. If CSF's csfpost.sh rules also applied to ip6tables (they don't in the current code — only `iptables` commands are used), this would be a gap. **Status:** Not currently a bug because the install only adds `iptables` (IPv4) rules to csfpost.sh, and `csf -r` handles ip6tables via the config. But if IPv6 knock rules are ever added, the uninstall chain cleanup would need `ip6tables` equivalents. Low priority — note for future.
