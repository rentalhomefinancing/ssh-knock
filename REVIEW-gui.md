# GUI Client Review — knock-gui.py & knock-gui.ps1

Reviewed: 2026-03-10

---

## Visual Design

- [ ] **Python: "Segoe UI" font missing on Linux/macOS** — The entire UI uses `"Segoe UI"` which is a Windows-only font. On Linux it falls back to a generic sans-serif (often ugly), on macOS it falls back unpredictably. Use a font tuple with cross-platform fallbacks: `("Segoe UI", "Helvetica Neue", "sans-serif", 10)` or use `tkinter.font.nametofont("TkDefaultFont")` and override its family list.

- [ ] **Python: "Consolas" font missing on Linux/macOS** — The knock sequence label and status bar use `"Consolas"` which is Windows-only. Linux needs `"DejaVu Sans Mono"` or `"Liberation Mono"`, macOS needs `"Menlo"`. Use a tuple: `("Consolas", "Menlo", "DejaVu Sans Mono", 9)`.

- [ ] **Python: Hard-coded pixel layout breaks with display scaling** — All widget placement uses `place()` with absolute x/y pixel coordinates and a fixed 400x370 window. On HiDPI screens (Windows 125%+, macOS Retina, GNOME fractional scaling) the content will clip or overlap. Replace `place()` layout with `pack()` or `grid()` geometry managers so tkinter can compute sizes dynamically.

- [ ] **Python: No DPI awareness declaration on Windows** — Windows will bitmap-scale the entire tkinter window, making it blurry on HiDPI displays. Call `ctypes.windll.shcore.SetProcessDpiAwareness(1)` before creating the `Tk()` root (guarded by `platform.system() == "Windows"`).

- [ ] **PowerShell: No DPI-per-monitor awareness** — The WPF window relies on system DPI. On multi-monitor setups with mixed scaling, the window may render blurry when dragged between screens. Add `[System.Windows.Media.RenderOptions]::ProcessRenderMode = 'Default'` and consider setting `dpiAwareness` in the manifest or using `SetProcessDpiAwareness`.

- [ ] **PowerShell: TextBox style missing CornerRadius** — The input card `Border` has `CornerRadius="8"` but the TextBox inputs are rectangular. Wrap each `TextBox` in a `Border` with `CornerRadius="4"` and set `TextBox BorderThickness="0"` to match the rounded theme.

- [ ] **PowerShell: No focus visual style on TextBox** — When a TextBox receives keyboard focus there is no visible indicator (the default WPF focus rect is suppressed by the custom style). Add a `Trigger` for `IsFocused` that changes `BorderBrush` to `#0ea5e9` on the input fields.

- [ ] **Python: Status label truncates long messages** — The status label has a fixed width and a single line. DNS error messages or "No terminal emulator found (tried x-terminal-emulator, gnome-terminal, konsole, xfce4-terminal, xterm)." will clip. Set `wraplength=340` on the status label so long messages wrap.

---

## UX Flow

- [ ] **Both: No Enter-key binding to trigger knock** — The user types a hostname and SSH user, then must reach for the mouse. Bind `<Return>` (Python) / `KeyDown Enter` (PowerShell) to fire the knock action. In Python: `self.root.bind("<Return>", lambda e: self._on_knock())`. In PowerShell: add a `KeyDown` handler on the window: `$window.Add_KeyDown({ if ($_.Key -eq 'Return') { $btnKnock.RaiseEvent(...) } })`.

- [ ] **Both: No visual progress indicator during knock** — The status text updates per-port, but there is no progress bar or animation showing progression. Add a thin progress bar (3 segments for 3 knocks) or at minimum a simple `[===>   ]` text indicator so the user can gauge how far along the sequence is.

- [ ] **Python: No Tab-order control** — Pressing Tab in the hostname field may not land on the SSH user field because `place()` does not establish tab order. Explicitly set `takefocus=True` and call `.tk_focusNext()` or use `grid()` which handles tab order automatically.

- [ ] **Both: "SSH session launched" gives no guidance on failure** — After reporting "SSH session launched (OpenSSH)." or "SSH session launched." the status goes green even if the SSH connection itself fails (wrong key, auth denied, connection refused). Add a note: "SSH session launched. If the terminal closes immediately, check your credentials." or monitor the subprocess exit code.

- [ ] **Python: Window does not receive focus on launch on macOS** — On macOS, tkinter windows often open behind other windows. Add `root.lift()` and `root.attributes('-topmost', True)` then `root.after(100, lambda: root.attributes('-topmost', False))` to ensure the window surfaces.

- [ ] **PowerShell: Button click handler does not re-focus the window** — After the SSH client launches via `Start-Process`, the knock window loses focus. The user may not see the "SSH session launched" status update. Call `$window.Activate()` in the `finally` block dispatcher invoke.

---

## Error Handling

- [ ] **Python: DNS resolution is only caught as `socket.gaierror`** — If the hostname resolves but the host is unreachable (e.g. no route), the knock loop will silently swallow the error inside `knock()` (the `OSError` catch) and still report success, then `launch_ssh` opens a terminal that immediately fails. Verify reachability after the knock sequence by attempting a TCP connect to `SSH_PORT` with a 3-second timeout before launching the terminal.

- [ ] **Python: No timeout ceiling on knock sequence** — If one knock port is routed to a host that SYN-ACKs and holds the connection open, `socket.connect()` will block for the full 1-second timeout per knock. With adversarial network conditions this means the GUI thread is only informed after each individual knock finishes. Consider reducing the per-knock timeout to 0.5s and adding a total-sequence timeout of 10s.

- [ ] **PowerShell: TcpClient not disposed on exception** — In `Send-KnockPacket`, if `BeginConnect` throws synchronously (e.g. invalid address), the `$tcp` object leaks because `Close()` is only called in the try block's happy path. Wrap in `try/finally` and call `$tcp.Dispose()` in the finally block.

- [ ] **PowerShell: Runspace and PowerShell objects never disposed** — `$ps` and `$runspace` are created on every button click but never cleaned up. Repeated clicks leak runspaces. Store `$ps` in a script-scoped variable, check if it is still running before creating a new one, and call `$ps.Dispose(); $runspace.Dispose()` in a completion callback or the finally block.

- [ ] **PowerShell: No DNS failure handling** — If the hostname is unresolvable, `TcpClient.BeginConnect` throws a `SocketException` which is silently caught in `Send-KnockPacket`. The sequence reports success and tries to launch SSH, which then fails. Pre-validate with `[System.Net.Dns]::GetHostEntry($hostname)` and surface a clear "DNS lookup failed" error.

- [ ] **Python: `launch_ssh` on Windows does not check for `ssh.exe` in PATH** — The Python client on Windows runs `cmd.exe /c start cmd.exe /k ssh ...`. If OpenSSH is not installed, the user sees a cryptic cmd.exe error flash. Check `shutil.which("ssh")` first and show a clear error: "No SSH client found. Install OpenSSH for Windows."

- [ ] **Both: No handling of firewall blocking outbound knock packets** — If a local firewall (Windows Firewall, ufw) blocks outbound SYN to the knock ports, the knock silently "succeeds" (exception is swallowed) but the sequence is never received server-side. Consider adding a note in the status: "If connection fails, ensure your firewall allows outbound TCP to ports [sequence]."

---

## Cross-Platform (Python Client)

- [ ] **Python: `gnome-terminal -- bash -c` does not pass `-l` flag** — The launched bash shell is not a login shell, so the user's `.bash_profile`/`.profile` are not sourced. SSH key agent variables (`SSH_AUTH_SOCK`) may be missing. Change to `bash -lc` instead of `bash -c`.

- [ ] **Python: macOS Terminal.app AppleScript injection vulnerability** — The `ssh_cmd` string is interpolated directly into AppleScript via `format()`. A malicious hostname like `foo"; do shell script "rm -rf ~" --"` would execute arbitrary commands. Escape the string for AppleScript by replacing `"` with `\"` and `\\` with `\\\\` before interpolation.

- [ ] **Python: Windows `cmd.exe /c start cmd.exe /k` fails with spaces in username** — If the SSH user contains a space (unlikely but possible), the command is not properly quoted. Wrap `ssh_cmd` in double quotes: `["cmd.exe", "/c", "start", "cmd.exe", "/k", '"{}"'.format(ssh_cmd)]`.

- [ ] **Python: No iTerm2 support on macOS** — Many macOS developers use iTerm2 instead of Terminal.app. The AppleScript hardcodes `"Terminal"`. Detect iTerm2 first by checking if the app bundle exists at `/Applications/iTerm.app`, and use its AppleScript interface: `tell application "iTerm" to create window with default profile command "ssh ..."`.

- [ ] **Python: Linux terminal detection tries `xterm` last but ignores Wayland terminals** — On Wayland desktops (GNOME 41+, Fedora default), `gnome-terminal` works but `xterm` will not if X11 is absent. More importantly, `foot`, `alacritty`, and `kitty` are common Wayland terminals not in the list. Add them before `xterm`: `["foot", "alacritty", "kitty"]`.

- [ ] **Python: macOS requires `python3-tk` which is not bundled with Homebrew Python by default** — If the user installed Python via Homebrew, `import tkinter` may fail with `ModuleNotFoundError`. The script has no graceful fallback — it just crashes. Add a try/except around `import tkinter` with a user-friendly error message: "tkinter is not installed. Run: brew install python-tk@3.x".

---

## Threading

- [ ] **Python: `self.busy` flag is not thread-safe** — `self.busy` is read/written from both the main thread and the knock thread without a lock. While CPython's GIL makes simple bool assignment atomic in practice, this is an implementation detail. Use `threading.Event` or `threading.Lock` for correctness, or only read/write `self.busy` via `root.after()`.

- [ ] **PowerShell: Runspace creation is STA but WPF Dispatcher calls may deadlock** — The background runspace is set to `ApartmentState = "STA"` which is correct, but `Dispatcher.Invoke` (synchronous) can deadlock if the UI thread is blocked. The UI thread is not explicitly blocked here, but as a safety measure use `Dispatcher.BeginInvoke` (async) instead of `Dispatcher.Invoke` throughout the background script.

- [ ] **PowerShell: Multiple rapid clicks can spawn multiple runspaces** — Although `$btnKnock.IsEnabled = $false` is set, there is a tiny race window between the click event firing and `IsEnabled` taking effect. A fast double-click can launch two runspaces. Add a script-scoped `$script:knockRunning = $false` guard checked inside the click handler before disabling the button.

---

## Input Validation

- [ ] **Both: No hostname format validation** — The user can type anything including shell metacharacters, backticks, semicolons, or newlines. These get passed to `socket.connect()` (Python) and `TcpClient.BeginConnect` (PowerShell) which will fail safely, but on the SSH launch side they get interpolated into command strings. Validate with a regex: `^[a-zA-Z0-9._-]+$` for hostnames or `^[0-9.]+$` for IPs. Reject anything else with a clear error.

- [ ] **Python: SSH username not validated — command injection risk** — The `user` variable is interpolated into `ssh_cmd` via string formatting and passed to `bash -c`, AppleScript `do script`, and `cmd.exe /k`. A username like `root; rm -rf /` would execute arbitrary commands. Validate SSH usernames with `^[a-zA-Z0-9._-]+$` and reject invalid input before constructing the command.

- [ ] **PowerShell: SSH arguments not sanitized** — `Start-Process "ssh.exe" -ArgumentList "-p $sshPort $user@$hostname"` interpolates user input. While `Start-Process` is safer than raw string execution, a hostname containing spaces or special characters could cause unexpected behavior. Validate both fields before use.

- [ ] **Both: No max-length check on input fields** — A user (or paste accident) could input thousands of characters into hostname or user fields. Set `maxlength` on the entry widgets. Python: configure the Entry with `validate="key"` and a `validatecommand` that rejects strings over 253 chars (DNS max). PowerShell: set `MaxLength="253"` on the TextBox.

---

## Accessibility

- [ ] **Python: Status text at 9pt Consolas is too small for many users** — The status area and knock sequence label use `("Consolas", 9)` which renders at roughly 12px — below WCAG minimum recommended size of 16px for body text. Increase to at least 10-11pt.

- [ ] **Python: No keyboard shortcut for the Connect button** — Power users expect Alt+key or Ctrl+Enter accelerators. Add an underline mnemonic: `text="Knock & _Connect"` does not work in tkinter, but `root.bind("<Control-Return>", ...)` would provide an alternative.

- [ ] **PowerShell: Button emoji (unlock icon U+1F513) may not render on all systems** — The lock emoji in the button text depends on the system font supporting it. On older Windows 10 builds or in restricted terminal fonts it renders as a missing-glyph box. Use a WPF `Path` or `TextBlock` with Segoe MDL2 Assets glyph instead, or remove the emoji and use text only.

- [ ] **Both: No tooltip/help text explaining what port knocking is** — A user unfamiliar with the concept sees "Knock Sequence: 12345 > 23456 > 34567" with no explanation. Add a tooltip or small help text: "Port knocking sends TCP packets to these ports in order, which tells the server to open the SSH port."

- [ ] **Python: Insufficient contrast on disabled button** — When disabled, the button changes to `bg="#475569"` with white text. The contrast ratio of #ffffff on #475569 is ~5.4:1 which passes AA but the color is visually confusing because it is the same gray used for input borders and subtle elements. Use a more obviously-disabled color like `#334155` with `fg="#64748b"` to make the disabled state unmistakable.

- [ ] **PowerShell: Window not keyboard-navigable on launch** — When the window opens, no element has focus. The user must click to start typing. Set `FocusManager.FocusedElement="{Binding ElementName=txtHost}"` on the `Window` element so the hostname field is focused on launch.

---

## Polish

- [ ] **Both: No window icon** — Both windows use the default tkinter feather (Python) or generic WPF icon (PowerShell). Set a custom icon: for Python use `root.iconbitmap()` or `root.iconphoto()` with an embedded base64 PNG of a lock/key. For PowerShell, set `Icon` property on the Window element or load a `.ico` from a resource.

- [ ] **Python: Window title bar shows just "SSH Knock"** — On Linux, the window class is set to `Tk` which some window managers display in task lists. Set `root.wm_class("ssh-knock", "SSH Knock")` so it appears correctly in taskbar/dock.

- [ ] **Python: No hover color on button via binding** — The tkinter `Button` widget's `activebackground` only applies while the mouse button is held down, not on hover. For a true hover effect matching the PowerShell WPF version, bind `<Enter>` and `<Leave>` events to change the button background color dynamically.

- [ ] **Python: Entry fields have no placeholder-style behavior** — When the hostname or user field is empty, there is no visual hint about what to type. The hostname field is pre-filled with `__HOSTNAME__` (the literal placeholder if unreplaced). Add a validation check: if the value is still `__HOSTNAME__`, treat it as empty and show an error like "Hostname not configured — edit this field."

- [ ] **PowerShell: No "Escape to close" binding** — Pressing Escape does nothing. Add: `$window.Add_KeyDown({ if ($_.Key -eq 'Escape') { $window.Close() } })`.

- [ ] **PowerShell: `[Environment]::Exit(0)` in `Closed` handler is aggressive** — This kills the entire PowerShell process immediately, including any parent shell. If the script was dot-sourced or run from an IDE, this kills the IDE. Use `$window.Close()` and let the script exit naturally after `ShowDialog()` returns. Remove the `Add_Closed` handler entirely.

- [ ] **Python: No graceful handling of window close during knock** — If the user closes the window while a knock thread is running, the thread continues executing and calls `self.root.after()` on a destroyed Tk root, which throws `TclError: can't invoke "after" command: application has been destroyed`. Set a `self.closing` flag in a `WM_DELETE_WINDOW` protocol handler and check it before each `root.after()` call.

- [ ] **Both: No "Copy error to clipboard" affordance** — When an error occurs (DNS failure, no SSH client), the user sees the message in a tiny status label but cannot easily copy it to send to an admin. Add a right-click context menu or a small copy button next to the status text.

- [ ] **Python: Card frame border color (`#334155`) blends into card background (`#1e293b`)** — The 1px highlight border is nearly invisible. Either increase to 2px or use a slightly lighter border like `#475569` for the card outline.
