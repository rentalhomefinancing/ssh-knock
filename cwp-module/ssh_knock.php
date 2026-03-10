<?php
/**
 * SSH Knock — CWP Admin Module
 * Port knocking manager for CSF firewalls
 *
 * Location: /usr/local/cwpsrv/htdocs/resources/admin/modules/ssh_knock.php
 * Access:   https://server:2031/index.php?module=ssh_knock
 *
 * Part of the ssh-knock project
 */

// ── Client file whitelist ────────────────────────────────────────────────

$allowedClients = [
    'knock.sh'      => ['mime' => 'application/x-sh',          'desc' => 'Linux/macOS CLI'],
    'knock.ps1'     => ['mime' => 'application/octet-stream',  'desc' => 'Windows PowerShell CLI'],
    'knock-gui.py'  => ['mime' => 'text/x-python',             'desc' => 'Linux/macOS GUI'],
    'knock-gui.ps1' => ['mime' => 'application/octet-stream',  'desc' => 'Windows GUI'],
];

// ── CSRF (file-based — CWP does not use PHP sessions) ───────────────────
// CWP includes modules after sending output, so session_start() is not
// possible. We use a file-based token instead.

$csrfFile = '/opt/ssh-knock/.csrf_token';
if (!file_exists($csrfFile) || !is_readable($csrfFile) || strlen(trim(file_get_contents($csrfFile))) !== 64) {
    $token = bin2hex(random_bytes(32));
    file_put_contents($csrfFile, $token);
    chmod($csrfFile, 0600);
}
$csrf = trim(file_get_contents($csrfFile));

// ── Helper Functions ─────────────────────────────────────────────────────

// Whitelisted config keys (only these are parsed and returned)
const SSHK_KNOWN_KEYS = ['SSH_PORT', 'KNOCK1', 'KNOCK2', 'KNOCK3', 'KNOCK_TIMEOUT', 'ACCESS_TIMEOUT'];

function sshk_parseConfig(): array {
    $path = '/opt/ssh-knock/config';
    if (!file_exists($path)) return [];
    $cfg = [];
    foreach (file($path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') continue;
        if (strpos($line, '=') === false) continue;
        [$key, $val] = explode('=', $line, 2);
        $key = trim($key);
        $val = trim($val);
        // Only accept known config keys with numeric values
        if (in_array($key, SSHK_KNOWN_KEYS, true) && ctype_digit($val)) {
            $cfg[$key] = (int) $val;
        }
    }
    return $cfg;
}

function sshk_isActive(): bool {
    return trim(shell_exec('systemctl is-active ssh-knock 2>/dev/null') ?? '') === 'active';
}

function sshk_isEnabled(): bool {
    return trim(shell_exec('systemctl is-enabled ssh-knock 2>/dev/null') ?? '') === 'enabled';
}

function sshk_uptime(): string {
    if (!sshk_isActive()) return '';
    return trim(shell_exec('systemctl show ssh-knock --property=ActiveEnterTimestamp --value 2>/dev/null') ?? '');
}

function sshk_logs(int $n = 40): string {
    return trim(shell_exec("tail -$n /var/log/ssh-knock.log 2>/dev/null") ?? '');
}

function sshk_journalLogs(int $n = 20): string {
    return trim(shell_exec("journalctl -u ssh-knock --no-pager -n $n 2>/dev/null") ?? '');
}

function sshk_auditLog(int $n = 20): string {
    return trim(shell_exec("tail -$n /opt/ssh-knock/audit.log 2>/dev/null") ?? '');
}

function sshk_audit(string $msg): void {
    $ts = date('Y-m-d H:i:s T');
    $msg = str_replace(["\r", "\n"], ' ', $msg);
    $written = file_put_contents('/opt/ssh-knock/audit.log', "[$ts] $msg\n", FILE_APPEND);
    if ($written === false) {
        error_log("SSH Knock: failed to write audit log");
    }
}

function sshk_hasSafetyRevert(): bool {
    $cron = shell_exec('crontab -l 2>/dev/null') ?? '';
    return strpos($cron, 'ssh-knock-regen-safety') !== false;
}

// ── POST Action Handler ──────────────────────────────────────────────────

$msg = '';
$msgType = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['sshk_action'])) {
    if (!hash_equals($csrf, $_POST['sshk_csrf'] ?? '')) {
        $msg = 'Security token mismatch. Refresh the page and try again.';
        $msgType = 'danger';
    } else {
        $action = $_POST['sshk_action'];
        switch ($action) {
            case 'start':
                shell_exec('systemctl start ssh-knock 2>&1');
                usleep(800000);
                $ok = sshk_isActive();
                $msg = $ok ? 'Daemon started.' : 'Failed to start daemon. Check logs below.';
                $msgType = $ok ? 'success' : 'danger';
                sshk_audit('ACTION: start — ' . ($ok ? 'success' : 'failed'));
                break;

            case 'stop':
                shell_exec('systemctl stop ssh-knock 2>&1');
                usleep(800000);
                $ok = !sshk_isActive();
                $msg = $ok
                    ? 'Daemon stopped. SSH port is currently unprotected — anyone with the IP can attempt SSH.'
                    : 'Failed to stop daemon.';
                $msgType = $ok ? 'warning' : 'danger';
                sshk_audit('ACTION: stop — ' . ($ok ? 'success' : 'failed'));
                break;

            case 'restart':
                shell_exec('systemctl restart ssh-knock 2>&1');
                usleep(1500000);
                $ok = sshk_isActive();
                $msg = $ok ? 'Daemon restarted.' : 'Failed to restart daemon. Check logs below.';
                $msgType = $ok ? 'success' : 'danger';
                sshk_audit('ACTION: restart — ' . ($ok ? 'success' : 'failed'));
                break;

            case 'regenerate':
                $out = trim(shell_exec('/opt/ssh-knock/regenerate-ports.sh 2>&1') ?? '');
                $firstLine = strtok($out, "\n");
                $ok = strpos($firstLine, 'OK:') === 0;
                if ($ok) {
                    $msg = htmlspecialchars($firstLine)
                        . '<br><strong>Re-download all client scripts.</strong>'
                        . '<br><small>A safety revert is scheduled in 5 minutes. Cancel it after confirming the new ports work.</small>';
                    $msgType = 'success';
                } else {
                    $msg = 'Port regeneration failed: ' . htmlspecialchars($firstLine);
                    $msgType = 'danger';
                }
                break;

            case 'cancel_safety':
                shell_exec("crontab -l 2>/dev/null | grep -v 'ssh-knock-regen-safety' | crontab - 2>/dev/null");
                shell_exec('rm -f /opt/ssh-knock/revert-regen.sh 2>/dev/null');
                $msg = 'Safety revert cancelled. New port configuration is now permanent.';
                $msgType = 'info';
                sshk_audit('ACTION: cancel_safety_revert');
                break;

            case 'uninstall_knock':
                if (($_POST['uninstall_confirm'] ?? '') !== 'UNINSTALL') {
                    $msg = 'Type UNINSTALL to confirm.';
                    $msgType = 'danger';
                    break;
                }
                if (file_exists('/opt/ssh-knock/uninstall.sh')) {
                    $out = shell_exec('bash /opt/ssh-knock/uninstall.sh --yes 2>&1');
                    $msg = 'SSH Knock uninstalled. SSH port is now open normally through CSF.';
                    $msgType = 'info';
                    sshk_audit('ACTION: uninstall_ssh_knock');
                } else {
                    $msg = 'Uninstall script not found at /opt/ssh-knock/uninstall.sh';
                    $msgType = 'danger';
                }
                break;

            default:
                $msg = 'Unknown action.';
                $msgType = 'danger';
        }
        // Validate msgType
        $validTypes = ['success', 'danger', 'warning', 'info'];
        $msgType = in_array($msgType, $validTypes, true) ? $msgType : 'danger';
        // Rotate CSRF token after action
        $csrf = bin2hex(random_bytes(32));
        file_put_contents($csrfFile, $csrf);
    }
}

// ── Read Current State ───────────────────────────────────────────────────

$installed = is_dir('/opt/ssh-knock') && file_exists('/opt/ssh-knock/config');
$config    = $installed ? sshk_parseConfig() : [];
$active    = sshk_isActive();
$enabled   = sshk_isEnabled();
$uptime    = sshk_uptime();
$hasSafety = sshk_hasSafetyRevert();

$clients = [];
if ($installed) {
    foreach (array_keys($allowedClients) as $c) {
        if (file_exists('/opt/ssh-knock/clients/' . $c)) {
            $clients[] = $c;
        }
    }
}

$logs      = $installed ? sshk_logs() : '';
$jLogs     = $installed ? sshk_journalLogs() : '';
$auditLogs = $installed ? sshk_auditLog() : '';

// ── Render HTML ──────────────────────────────────────────────────────────
?>

<style>
.sshk-wrap { max-width: 1200px; }
.sshk-stat { background: #f8f9fa; border: 1px solid #e0e0e0; border-radius: 6px; padding: 16px; text-align: center; }
.sshk-stat .value { font-size: 22px; font-weight: 700; color: #333; }
.sshk-stat .label { font-size: 12px; color: #888; text-transform: uppercase; margin-top: 4px; }
.sshk-badge { display: inline-block; padding: 4px 12px; border-radius: 12px; font-size: 13px; font-weight: 600; }
.sshk-badge-active { background: #27ae60; color: #fff; }
.sshk-badge-inactive { background: #c0392b; color: #fff; }
.sshk-badge-safety { background: #f39c12; color: #fff; }
.sshk-knock-seq { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 12px 0; }
.sshk-port-box { display: inline-block; background: #2c3e50; color: #f1c40f; font-size: 18px; font-weight: 700;
    padding: 10px 18px; border-radius: 8px; font-family: monospace; letter-spacing: 1px; }
.sshk-arrow { font-size: 20px; color: #999; }
.sshk-dl-card { border: 1px solid #ddd; border-radius: 8px; padding: 14px; margin-bottom: 10px;
    transition: box-shadow 0.2s, transform 0.2s; cursor: default; }
.sshk-dl-card:hover { box-shadow: 0 4px 12px rgba(0,0,0,0.1); transform: translateY(-2px); }
.sshk-dl-card .dl-icon { font-size: 28px; margin-bottom: 6px; }
.sshk-dl-card .dl-name { font-weight: 600; font-size: 14px; }
.sshk-dl-card .dl-desc { font-size: 12px; color: #888; margin-bottom: 8px; }
.sshk-log-box { max-height: 350px; overflow-y: auto; background: #1a1a2e; color: #16c784; font-family: monospace;
    font-size: 12px; padding: 14px; border-radius: 6px; white-space: pre-wrap; word-break: break-all; }
.sshk-section { margin-bottom: 24px; }
.sshk-actions .btn { margin-right: 6px; margin-bottom: 6px; }
.sshk-confirm-input { width: 100%; padding: 8px; font-size: 14px; border: 1px solid #ddd; border-radius: 4px; margin-top: 8px; }
</style>

<div class="sshk-wrap">
    <h2><span class="glyphicon glyphicon-lock"></span> SSH Knock — Port Knocking Manager</h2>
    <p style="color:#888; margin-bottom: 20px;">
        Manage SSH port-knock protection for this server.
        <?php if ($installed && $active): ?>
            <span class="sshk-badge sshk-badge-active">Active</span>
        <?php elseif ($installed): ?>
            <span class="sshk-badge sshk-badge-inactive">Stopped</span>
        <?php endif; ?>
        <?php if ($hasSafety): ?>
            <span class="sshk-badge sshk-badge-safety">Safety Revert Pending</span>
        <?php endif; ?>
    </p>

    <?php if ($msg): ?>
    <div class="alert alert-<?= htmlspecialchars($msgType) ?> alert-dismissable">
        <button type="button" class="close" data-dismiss="alert">&times;</button>
        <?= $msg ?>
    </div>
    <?php endif; ?>

    <?php if (!$installed): ?>
    <!-- ─── Not Installed State ─────────────────────────────────────── -->
    <div class="panel panel-default">
        <div class="panel-body" style="text-align:center; padding: 60px 20px;">
            <span class="glyphicon glyphicon-lock" style="font-size:64px; color:#ccc;"></span>
            <h3>SSH Knock is not installed</h3>
            <p style="color:#888;">Install SSH Knock to enable port-knocking protection for SSH access.</p>
            <p><code>cd /usr/local/src/ssh-knock && ./install.sh</code></p>
        </div>
    </div>

    <?php else: ?>
    <!-- ─── Status Cards ────────────────────────────────────────────── -->
    <div class="row sshk-section">
        <div class="col-md-3 col-sm-6" style="margin-bottom:10px;">
            <div class="sshk-stat">
                <div class="value">
                    <?php if ($active): ?>
                        <span style="color:#27ae60;">&#9679;</span> Running
                    <?php else: ?>
                        <span style="color:#c0392b;">&#9679;</span> Stopped
                    <?php endif; ?>
                </div>
                <div class="label">Daemon Status</div>
            </div>
        </div>
        <div class="col-md-3 col-sm-6" style="margin-bottom:10px;">
            <div class="sshk-stat">
                <div class="value"><?= (int)($config['SSH_PORT'] ?? 22) ?></div>
                <div class="label">SSH Port</div>
            </div>
        </div>
        <div class="col-md-3 col-sm-6" style="margin-bottom:10px;">
            <div class="sshk-stat">
                <div class="value"><?= (int)($config['KNOCK_TIMEOUT'] ?? 10) ?>s</div>
                <div class="label">Knock Timeout</div>
            </div>
        </div>
        <div class="col-md-3 col-sm-6" style="margin-bottom:10px;">
            <div class="sshk-stat">
                <div class="value"><?= (int)($config['ACCESS_TIMEOUT'] ?? 30) ?>s</div>
                <div class="label">Access Window</div>
            </div>
        </div>
    </div>

    <!-- ─── Knock Sequence + Config ─────────────────────────────────── -->
    <div class="row sshk-section">
        <div class="col-md-7">
            <div class="panel panel-default">
                <div class="panel-heading"><strong>Knock Sequence</strong></div>
                <div class="panel-body">
                    <div class="sshk-knock-seq">
                        <span class="sshk-port-box"><?= (int)($config['KNOCK1'] ?? 0) ?></span>
                        <span class="sshk-arrow">&rarr;</span>
                        <span class="sshk-port-box"><?= (int)($config['KNOCK2'] ?? 0) ?></span>
                        <span class="sshk-arrow">&rarr;</span>
                        <span class="sshk-port-box"><?= (int)($config['KNOCK3'] ?? 0) ?></span>
                    </div>
                    <p style="color:#888; font-size:13px; margin-top:10px;">
                        Send TCP SYN packets to these ports in order within <?= (int)($config['KNOCK_TIMEOUT'] ?? 10) ?>s.
                        After a successful knock, SSH is open for <?= (int)($config['ACCESS_TIMEOUT'] ?? 30) ?>s.
                    </p>
                    <?php if ($uptime): ?>
                    <p style="color:#888; font-size:12px;">
                        <strong>Running since:</strong> <?= htmlspecialchars($uptime) ?>
                    </p>
                    <?php endif; ?>
                </div>
            </div>
        </div>
        <div class="col-md-5">
            <div class="panel panel-default">
                <div class="panel-heading"><strong>Configuration</strong></div>
                <div class="panel-body" style="padding:0;">
                    <table class="table table-bordered table-striped" style="margin:0;">
                        <tbody>
                        <?php foreach ($config as $key => $val): ?>
                            <tr>
                                <td style="font-weight:600; width:50%;"><?= htmlspecialchars($key) ?></td>
                                <td><code><?= (int) $val ?></code></td>
                            </tr>
                        <?php endforeach; ?>
                            <tr>
                                <td style="font-weight:600;">Enabled on Boot</td>
                                <td><?= $enabled ? '<span style="color:#27ae60;">Yes</span>' : '<span style="color:#c0392b;">No</span>' ?></td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>

    <!-- ─── Controls ────────────────────────────────────────────────── -->
    <div class="panel panel-default sshk-section">
        <div class="panel-heading"><strong>Controls</strong></div>
        <div class="panel-body sshk-actions">
            <!-- Daemon controls -->
            <form method="post" style="display:inline;">
                <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                <input type="hidden" name="sshk_action" value="start">
                <button type="submit" class="btn btn-success btn-sm" <?= $active ? 'disabled' : '' ?>>
                    <span class="glyphicon glyphicon-play"></span> Start
                </button>
            </form>
            <form method="post" style="display:inline;" onsubmit="return confirm('Stop the daemon? SSH will be unprotected until restarted.');">
                <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                <input type="hidden" name="sshk_action" value="stop">
                <button type="submit" class="btn btn-warning btn-sm" <?= !$active ? 'disabled' : '' ?>>
                    <span class="glyphicon glyphicon-stop"></span> Stop
                </button>
            </form>
            <form method="post" style="display:inline;">
                <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                <input type="hidden" name="sshk_action" value="restart">
                <button type="submit" class="btn btn-info btn-sm" <?= !$active ? 'disabled' : '' ?>>
                    <span class="glyphicon glyphicon-refresh"></span> Restart
                </button>
            </form>

            <span style="display:inline-block; width:20px;"></span>

            <!-- Regenerate Ports -->
            <button type="button" class="btn btn-primary btn-sm" data-toggle="modal" data-target="#regenModal" <?= !$active ? 'disabled' : '' ?>>
                <span class="glyphicon glyphicon-random"></span> Regenerate Ports
            </button>

            <?php if ($hasSafety): ?>
            <!-- Cancel Safety Revert -->
            <form method="post" style="display:inline;" onsubmit="return confirm('Cancel the safety revert? The new port configuration will be permanent.');">
                <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                <input type="hidden" name="sshk_action" value="cancel_safety">
                <button type="submit" class="btn btn-default btn-sm" style="border-color:#f39c12; color:#f39c12;">
                    <span class="glyphicon glyphicon-remove-circle"></span> Cancel Safety Revert
                </button>
            </form>
            <?php endif; ?>

            <span style="display:inline-block; width:20px;"></span>

            <!-- Uninstall -->
            <button type="button" class="btn btn-danger btn-sm" data-toggle="modal" data-target="#uninstallModal">
                <span class="glyphicon glyphicon-trash"></span> Uninstall SSH Knock
            </button>
        </div>
    </div>

    <!-- ─── Client Downloads ────────────────────────────────────────── -->
    <?php if (!empty($clients)): ?>
    <div class="panel panel-default sshk-section">
        <div class="panel-heading"><strong>Client Downloads</strong></div>
        <div class="panel-body">
            <?php if ($hasSafety): ?>
            <div class="alert alert-warning" style="margin-bottom:14px;">
                <strong>Ports were recently regenerated.</strong> Download fresh client scripts before the safety revert expires.
            </div>
            <?php endif; ?>
            <div class="row">
            <?php
            $icons = [
                'knock.sh'      => ['icon' => '&#128427;', 'color' => '#27ae60'],
                'knock.ps1'     => ['icon' => '&#128187;', 'color' => '#2980b9'],
                'knock-gui.py'  => ['icon' => '&#128424;', 'color' => '#8e44ad'],
                'knock-gui.ps1' => ['icon' => '&#128424;', 'color' => '#2c3e50'],
            ];
            // Pre-encode client files as base64 for JS blob downloads
            $clientData = [];
            foreach ($clients as $c) {
                $path = '/opt/ssh-knock/clients/' . $c;
                if (is_readable($path)) {
                    $clientData[$c] = base64_encode(file_get_contents($path));
                }
            }
            foreach ($clients as $c):
                $meta = $allowedClients[$c] ?? ['desc' => $c];
                $ic = $icons[$c] ?? ['icon' => '&#128196;', 'color' => '#555'];
                $hasData = isset($clientData[$c]);
            ?>
                <div class="col-md-3 col-sm-6">
                    <div class="sshk-dl-card" style="border-left: 3px solid <?= $ic['color'] ?>;">
                        <div class="dl-icon"><?= $ic['icon'] ?></div>
                        <div class="dl-name"><?= htmlspecialchars($c) ?></div>
                        <div class="dl-desc"><?= htmlspecialchars($meta['desc']) ?></div>
                        <?php if ($hasData): ?>
                        <button type="button" class="btn btn-default btn-xs"
                                onclick="sshkDownload('<?= htmlspecialchars($c) ?>')">
                            <span class="glyphicon glyphicon-download-alt"></span> Download
                        </button>
                        <?php else: ?>
                        <button type="button" class="btn btn-default btn-xs" disabled
                                title="File not readable on server">
                            <span class="glyphicon glyphicon-ban-circle"></span> Unavailable
                        </button>
                        <?php endif; ?>
                    </div>
                </div>
            <?php endforeach; ?>
            </div>
        </div>
    </div>
    <!-- Base64 client data for JS blob downloads -->
    <script>
    var sshkClientFiles = <?= json_encode($clientData) ?>;
    function sshkDownload(name) {
        var b64 = sshkClientFiles[name];
        if (!b64) { alert('File not available.'); return; }
        var raw = atob(b64);
        var arr = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
        var blob = new Blob([arr], { type: 'application/octet-stream' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url; a.download = name;
        document.body.appendChild(a); a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    }
    </script>
    <?php endif; ?>

    <!-- ─── Client Setup Guide ─────────────────────────────────────── -->
    <div class="panel panel-default sshk-section">
        <div class="panel-heading">
            <strong>Client Setup Guide</strong>
            <span class="label label-info pull-right" style="margin-top:2px;">After downloading, follow these steps</span>
        </div>
        <div class="panel-body">
            <p style="color:#888; margin-bottom:16px;">
                Each client has the knock sequence and server address baked in. Download, set up, and run &mdash; it knocks then auto-connects via SSH.
            </p>

            <!-- Linux/macOS CLI -->
            <div class="panel panel-default" style="margin-bottom:12px;">
                <div class="panel-heading" style="padding:8px 14px; cursor:pointer;" data-toggle="collapse" data-target="#guide-sh">
                    <strong style="color:#27ae60;">&#128427; knock.sh</strong> &mdash; Linux / macOS Terminal
                    <span class="glyphicon glyphicon-chevron-down pull-right" style="color:#999;"></span>
                </div>
                <div id="guide-sh" class="panel-collapse collapse">
                    <div class="panel-body" style="font-size:13px;">
                        <p><strong>Requirements:</strong> Bash (pre-installed on Linux and macOS)</p>
                        <p><strong>Setup:</strong></p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Make it executable
chmod +x knock.sh

# Run it
./knock.sh yourserver.com

# With a specific SSH user
./knock.sh yourserver.com admin</pre>
                        <p style="margin-top:8px;">The script sends the 3-port knock sequence, waits 1 second, then opens an SSH connection in your current terminal. If no username is provided, it defaults to <code>root</code>.</p>
                    </div>
                </div>
            </div>

            <!-- Windows CLI -->
            <div class="panel panel-default" style="margin-bottom:12px;">
                <div class="panel-heading" style="padding:8px 14px; cursor:pointer;" data-toggle="collapse" data-target="#guide-ps1">
                    <strong style="color:#2980b9;">&#128187; knock.ps1</strong> &mdash; Windows PowerShell Terminal
                    <span class="glyphicon glyphicon-chevron-down pull-right" style="color:#999;"></span>
                </div>
                <div id="guide-ps1" class="panel-collapse collapse">
                    <div class="panel-body" style="font-size:13px;">
                        <p><strong>Requirements:</strong> PowerShell 3.0+ and OpenSSH or PuTTY</p>
                        <p><strong>First-time setup</strong> (if scripts are blocked):</p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Allow running local scripts (one-time)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser</pre>
                        <p><strong>Run:</strong></p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Basic usage
.\knock.ps1 -HostName yourserver.com

# With a specific SSH user
.\knock.ps1 -HostName yourserver.com -User admin</pre>
                        <p style="margin-top:8px;">Sends the knock sequence then connects via <code>ssh.exe</code> (Windows 10 1803+) or PuTTY if installed. Defaults to user <code>root</code>.</p>
                    </div>
                </div>
            </div>

            <!-- Linux/macOS GUI -->
            <div class="panel panel-default" style="margin-bottom:12px;">
                <div class="panel-heading" style="padding:8px 14px; cursor:pointer;" data-toggle="collapse" data-target="#guide-guipy">
                    <strong style="color:#8e44ad;">&#128424; knock-gui.py</strong> &mdash; Linux / macOS / Windows GUI
                    <span class="glyphicon glyphicon-chevron-down pull-right" style="color:#999;"></span>
                </div>
                <div id="guide-guipy" class="panel-collapse collapse">
                    <div class="panel-body" style="font-size:13px;">
                        <p><strong>Requirements:</strong> Python 3.6+ with tkinter</p>
                        <p><strong>Install tkinter</strong> (if not already installed):</p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Debian / Ubuntu
sudo apt install python3-tk

# Fedora / RHEL / CentOS
sudo dnf install python3-tkinter

# macOS (Homebrew)
brew install python-tk

# Windows: reinstall Python from python.org
# and check "tcl/tk and IDLE" during install</pre>
                        <p><strong>Run:</strong></p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Linux / macOS
chmod +x knock-gui.py
./knock-gui.py

# Or run with Python directly (any platform)
python3 knock-gui.py</pre>
                        <p style="margin-top:8px;">Opens a GUI window with hostname and username fields pre-filled. Click <strong>Knock &amp; Connect</strong> to send the sequence and auto-launch SSH in your native terminal (gnome-terminal, iTerm2, Terminal.app, cmd.exe, etc.).</p>
                    </div>
                </div>
            </div>

            <!-- Windows GUI -->
            <div class="panel panel-default" style="margin-bottom:0;">
                <div class="panel-heading" style="padding:8px 14px; cursor:pointer;" data-toggle="collapse" data-target="#guide-guips1">
                    <strong style="color:#2c3e50;">&#128424; knock-gui.ps1</strong> &mdash; Windows GUI
                    <span class="glyphicon glyphicon-chevron-down pull-right" style="color:#999;"></span>
                </div>
                <div id="guide-guips1" class="panel-collapse collapse">
                    <div class="panel-body" style="font-size:13px;">
                        <p><strong>Requirements:</strong> Windows 10+ with PowerShell 3.0+ (built-in)</p>
                        <p><strong>Run:</strong></p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
# Option 1: Right-click the file > "Run with PowerShell"

# Option 2: From a PowerShell terminal
.\knock-gui.ps1</pre>
                        <p style="margin-top:8px;">If you see a security prompt, choose <strong>"Run once"</strong> or set the execution policy:</p>
<pre style="background:#1a1a2e; color:#16c784; padding:12px; border-radius:6px; font-size:12px;">
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser</pre>
                        <p style="margin-top:8px;">Opens a native Windows GUI with hostname and username fields. Click <strong>Knock &amp; Connect</strong> to knock and auto-launch SSH via OpenSSH or PuTTY. Shows a progress bar during the knock sequence.</p>
                    </div>
                </div>
            </div>

            <hr style="margin:18px 0 12px;">
            <p style="color:#888; font-size:12px; margin:0;">
                <span class="glyphicon glyphicon-info-sign"></span>
                <strong>After port regeneration</strong>, all existing client scripts become invalid. Download fresh copies from the cards above.
                The knock sequence is embedded in each script &mdash; there is no external config file.
            </p>
        </div>
    </div>

    <!-- ─── Logs ────────────────────────────────────────────────────── -->
    <div class="panel panel-default sshk-section">
        <div class="panel-heading">
            <strong>Logs</strong>
            <button class="btn btn-default btn-xs pull-right" onclick="location.reload();">
                <span class="glyphicon glyphicon-refresh"></span> Refresh
            </button>
        </div>
        <div class="panel-body">
            <!-- Tab navigation -->
            <ul class="nav nav-tabs" style="margin-bottom:14px;">
                <li class="active"><a data-toggle="tab" href="#sshk-log-daemon">Daemon Log</a></li>
                <li><a data-toggle="tab" href="#sshk-log-journal">Systemd Journal</a></li>
                <li><a data-toggle="tab" href="#sshk-log-audit">Audit Log</a></li>
            </ul>
            <div class="tab-content">
                <div id="sshk-log-daemon" class="tab-pane active">
                    <div class="sshk-log-box"><?= $logs ? htmlspecialchars($logs) : 'No log entries.' ?></div>
                </div>
                <div id="sshk-log-journal" class="tab-pane">
                    <div class="sshk-log-box"><?= $jLogs ? htmlspecialchars($jLogs) : 'No journal entries.' ?></div>
                </div>
                <div id="sshk-log-audit" class="tab-pane">
                    <div class="sshk-log-box"><?= $auditLogs ? htmlspecialchars($auditLogs) : 'No audit entries.' ?></div>
                </div>
            </div>
        </div>
    </div>

    <?php endif; // end installed check ?>
</div>

<!-- ─── Regenerate Ports Modal ────────────────────────────────────────── -->
<div class="modal fade" id="regenModal" tabindex="-1">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header">
                <button type="button" class="close" data-dismiss="modal">&times;</button>
                <h4 class="modal-title"><span class="glyphicon glyphicon-random"></span> Regenerate Knock Ports</h4>
            </div>
            <div class="modal-body">
                <div class="alert alert-warning">
                    <strong>This will:</strong>
                    <ul style="margin-top:8px;">
                        <li>Generate 3 new random knock ports</li>
                        <li>Restart the knock daemon with the new sequence</li>
                        <li>Invalidate all previously downloaded client scripts</li>
                    </ul>
                </div>
                <div class="alert alert-info">
                    <strong>Safety net:</strong> A dead-man's-switch will automatically revert to the current ports
                    in 5 minutes if you don't cancel it. This protects against lockout if the new ports have issues.
                </div>
                <p><strong>Your current SSH session will remain active.</strong> Test the new knock from another terminal before cancelling the safety revert.</p>
            </div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-dismiss="modal">Cancel</button>
                <form method="post" style="display:inline;">
                    <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                    <input type="hidden" name="sshk_action" value="regenerate">
                    <button type="submit" class="btn btn-primary">
                        <span class="glyphicon glyphicon-random"></span> Regenerate Now
                    </button>
                </form>
            </div>
        </div>
    </div>
</div>

<!-- ─── Uninstall Modal ───────────────────────────────────────────────── -->
<div class="modal fade" id="uninstallModal" tabindex="-1">
    <div class="modal-dialog">
        <div class="modal-content">
            <div class="modal-header" style="background:#c0392b; color:#fff;">
                <button type="button" class="close" data-dismiss="modal" style="color:#fff;">&times;</button>
                <h4 class="modal-title"><span class="glyphicon glyphicon-warning-sign"></span> Uninstall SSH Knock</h4>
            </div>
            <div class="modal-body">
                <div class="alert alert-danger">
                    <strong>This will permanently remove SSH Knock from this server:</strong>
                    <ul style="margin-top:8px;">
                        <li>Stop and remove the knock daemon</li>
                        <li>Re-add SSH port to CSF allowed ports</li>
                        <li>Restart CSF firewall</li>
                        <li>Remove all SSH Knock files from /opt/ssh-knock/</li>
                    </ul>
                </div>
                <p>After uninstall, SSH will be accessible normally without port knocking. This CWP module will remain installed but show "not installed" status.</p>
                <p><strong>Type UNINSTALL to confirm:</strong></p>
                <input type="text" id="sshk-uninstall-confirm" class="sshk-confirm-input"
                       placeholder="Type UNINSTALL here" autocomplete="off">
            </div>
            <div class="modal-footer">
                <button type="button" class="btn btn-default" data-dismiss="modal">Cancel</button>
                <form method="post" style="display:inline;" id="sshk-uninstall-form">
                    <input type="hidden" name="sshk_csrf" value="<?= htmlspecialchars($csrf) ?>">
                    <input type="hidden" name="sshk_action" value="uninstall_knock">
                    <input type="hidden" name="uninstall_confirm" id="sshk-uninstall-confirm-hidden" value="">
                    <button type="submit" class="btn btn-danger" id="sshk-uninstall-btn" disabled>
                        <span class="glyphicon glyphicon-trash"></span> Uninstall
                    </button>
                </form>
            </div>
        </div>
    </div>
</div>

<script>
// Enable uninstall button only when user types UNINSTALL
(function() {
    var input = document.getElementById('sshk-uninstall-confirm');
    var btn = document.getElementById('sshk-uninstall-btn');
    var hidden = document.getElementById('sshk-uninstall-confirm-hidden');
    if (input && btn && hidden) {
        input.addEventListener('input', function() {
            var val = this.value.trim();
            btn.disabled = (val !== 'UNINSTALL');
            hidden.value = val;
        });
    }

    // Auto-scroll log boxes to bottom
    var logBoxes = document.querySelectorAll('.sshk-log-box');
    for (var i = 0; i < logBoxes.length; i++) {
        logBoxes[i].scrollTop = logBoxes[i].scrollHeight;
    }
})();
</script>
