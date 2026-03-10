#!/usr/bin/env python3
"""
SSH Knock — Port-knock then connect over SSH.

Placeholders replaced at install time:
    __HOSTNAME__   — target host
    __KNOCK1__     — first knock port
    __KNOCK2__     — second knock port
    __KNOCK3__     — third knock port
    __SSH_PORT__   — SSH listen port
"""

import os
import sys
import socket
import platform
import subprocess
import threading
import tkinter as tk

# ---------------------------------------------------------------------------
# Placeholders (server install replaces these with real values)
# ---------------------------------------------------------------------------
HOSTNAME   = "__HOSTNAME__"
KNOCK_SEQ  = [__KNOCK1__, __KNOCK2__, __KNOCK3__]
SSH_PORT   = __SSH_PORT__
KNOCK_DELAY = 0.3          # seconds between knocks

# ---------------------------------------------------------------------------
# Colours — matches the 2FA gate dark theme
# ---------------------------------------------------------------------------
BG_DARK    = "#0f172a"
BG_CARD    = "#1e293b"
ACCENT     = "#0ea5e9"
ACCENT_HVR = "#38bdf8"
TEXT_PRI   = "#f1f5f9"
TEXT_SEC   = "#94a3b8"
TEXT_DIM   = "#64748b"
SUCCESS    = "#22c55e"
ERROR      = "#ef4444"


# ---------------------------------------------------------------------------
# Port-knock logic
# ---------------------------------------------------------------------------
def knock(host, port, timeout=1.0):
    """Send a single TCP SYN to *host*:*port*.

    Connection-refused / timeout is expected — the knock daemon just needs
    to see the SYN.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
    except (socket.timeout, ConnectionRefusedError, OSError):
        pass  # normal — knock ports are not listening
    finally:
        s.close()


def launch_ssh(host, user, port):
    """Open an interactive SSH session in whatever terminal is available."""
    ssh_cmd = "ssh -o StrictHostKeyChecking=no -p {} {}@{}".format(port, user, host)
    system = platform.system()

    if system == "Linux":
        for term in ["x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal", "xterm"]:
            # gnome-terminal uses "--" to separate its flags from the command
            if term == "gnome-terminal":
                cmd = [term, "--", "bash", "-c", ssh_cmd + "; exec bash"]
            else:
                cmd = [term, "-e", ssh_cmd]
            try:
                subprocess.Popen(cmd)
                return None
            except FileNotFoundError:
                continue
        return "No terminal emulator found (tried x-terminal-emulator, gnome-terminal, konsole, xfce4-terminal, xterm)."

    elif system == "Darwin":
        # AppleScript drives Terminal.app
        script = (
            'tell application "Terminal"\n'
            '    activate\n'
            '    do script "{}"\n'
            'end tell'
        ).format(ssh_cmd)
        try:
            subprocess.Popen(["osascript", "-e", script])
            return None
        except FileNotFoundError:
            return "osascript not found — cannot open Terminal.app."

    elif system == "Windows":
        try:
            subprocess.Popen(["cmd.exe", "/c", "start", "cmd.exe", "/k", ssh_cmd])
            return None
        except FileNotFoundError:
            return "cmd.exe not found."

    else:
        return "Unsupported platform: {}".format(system)


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
class KnockApp(object):
    def __init__(self, root):
        self.root = root
        self.root.title("SSH Knock")
        self.root.configure(bg=BG_DARK)
        self.root.resizable(False, False)

        # Centre the window roughly
        w, h = 400, 370
        sx = root.winfo_screenwidth()
        sy = root.winfo_screenheight()
        x = (sx - w) // 2
        y = (sy - h) // 2
        root.geometry("{}x{}+{}+{}".format(w, h, x, y))

        self.busy = False
        self._build_ui()

    # ---- helpers ----------------------------------------------------------
    def _label(self, parent, text, **kw):
        defaults = dict(bg=BG_CARD, fg=TEXT_PRI, font=("Segoe UI", 10))
        defaults.update(kw)
        return tk.Label(parent, text=text, **defaults)

    def _entry(self, parent, textvariable, **kw):
        return tk.Entry(
            parent,
            textvariable=textvariable,
            bg="#334155",
            fg=TEXT_PRI,
            insertbackground=TEXT_PRI,
            relief="flat",
            font=("Segoe UI", 10),
            highlightthickness=1,
            highlightcolor=ACCENT,
            highlightbackground="#475569",
            **kw
        )

    # ---- build ------------------------------------------------------------
    def _build_ui(self):
        pad = 16

        # -- Card frame -----------------------------------------------------
        card = tk.Frame(self.root, bg=BG_CARD, highlightbackground="#334155",
                        highlightthickness=1)
        card.place(x=pad, y=pad, width=400 - 2 * pad, height=370 - 2 * pad)

        inner_pad = 14
        y_cursor = inner_pad

        # Title
        title = tk.Label(card, text="SSH Knock", bg=BG_CARD, fg=TEXT_PRI,
                         font=("Segoe UI", 15, "bold"))
        title.place(x=inner_pad, y=y_cursor)
        y_cursor += 34

        # Divider
        div = tk.Frame(card, bg="#334155", height=1)
        div.place(x=inner_pad, y=y_cursor, width=400 - 2 * pad - 2 * inner_pad)
        y_cursor += 10

        # Hostname
        self._label(card, "Hostname").place(x=inner_pad, y=y_cursor)
        y_cursor += 22
        self.var_host = tk.StringVar(value=HOSTNAME)
        self._entry(card, self.var_host).place(x=inner_pad, y=y_cursor,
                                               width=400 - 2 * pad - 2 * inner_pad - 2, height=28)
        y_cursor += 36

        # SSH User
        self._label(card, "SSH User").place(x=inner_pad, y=y_cursor)
        y_cursor += 22
        self.var_user = tk.StringVar(value="root")
        self._entry(card, self.var_user).place(x=inner_pad, y=y_cursor,
                                               width=400 - 2 * pad - 2 * inner_pad - 2, height=28)
        y_cursor += 36

        # Settings (read-only knock sequence)
        self._label(card, "Knock Sequence", fg=TEXT_SEC,
                    font=("Segoe UI", 9)).place(x=inner_pad, y=y_cursor)
        y_cursor += 20
        seq_text = "  >  ".join(str(p) for p in KNOCK_SEQ) + "  >  SSH :" + str(SSH_PORT)
        self._label(card, seq_text, fg=TEXT_DIM,
                    font=("Consolas", 9)).place(x=inner_pad, y=y_cursor)
        y_cursor += 28

        # -- Button ---------------------------------------------------------
        self.btn = tk.Button(
            card,
            text="Knock & Connect",
            bg=ACCENT,
            fg="#ffffff",
            activebackground=ACCENT_HVR,
            activeforeground="#ffffff",
            font=("Segoe UI", 11, "bold"),
            relief="flat",
            cursor="hand2",
            command=self._on_knock,
        )
        self.btn.place(x=inner_pad, y=y_cursor,
                       width=400 - 2 * pad - 2 * inner_pad - 2, height=38)
        y_cursor += 48

        # -- Status area ----------------------------------------------------
        self.status = tk.Label(card, text="Ready", bg=BG_CARD, fg=TEXT_SEC,
                               font=("Consolas", 9), anchor="w", justify="left")
        self.status.place(x=inner_pad, y=y_cursor,
                          width=400 - 2 * pad - 2 * inner_pad - 2)

    # ---- actions ----------------------------------------------------------
    def _set_status(self, text, colour=TEXT_SEC):
        self.status.configure(text=text, fg=colour)

    def _on_knock(self):
        if self.busy:
            return

        host = self.var_host.get().strip()
        user = self.var_user.get().strip()
        if not host:
            self._set_status("Error: hostname is empty", ERROR)
            return
        if not user:
            self._set_status("Error: SSH user is empty", ERROR)
            return

        self.busy = True
        self.btn.configure(state="disabled", bg="#475569")
        self._set_status("Starting knock sequence...", ACCENT)

        t = threading.Thread(target=self._knock_thread, args=(host, user), daemon=True)
        t.start()

    def _knock_thread(self, host, user):
        import time

        try:
            for i, port in enumerate(KNOCK_SEQ, 1):
                self.root.after(0, self._set_status,
                                "Knocking port {} ({}/{})...".format(port, i, len(KNOCK_SEQ)),
                                ACCENT)
                knock(host, port)
                time.sleep(KNOCK_DELAY)

            self.root.after(0, self._set_status, "Knock complete — launching SSH...", SUCCESS)
            time.sleep(0.2)

            err = launch_ssh(host, user, SSH_PORT)
            if err:
                self.root.after(0, self._set_status, err, ERROR)
            else:
                self.root.after(0, self._set_status, "SSH session launched.", SUCCESS)

        except socket.gaierror:
            self.root.after(0, self._set_status,
                            "DNS lookup failed for {}".format(host), ERROR)
        except Exception as exc:
            self.root.after(0, self._set_status, str(exc), ERROR)
        finally:
            self.root.after(0, self._finish)

    def _finish(self):
        self.busy = False
        self.btn.configure(state="normal", bg=ACCENT)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main():
    root = tk.Tk()
    KnockApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
