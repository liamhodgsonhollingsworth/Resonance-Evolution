"""
Native Tk login window for Apeiron. Pre-engine authentication gate.

Shows a sign-in form when accounts exist, or a create-account form when
the store is empty (the bootstrap path). The "Create new account" link
switches the form mode; the "Back to sign in" link goes back. On
successful sign-in (or successful create-then-auto-sign-in) the window
closes and the authenticated username is returned. On cancel (Escape or
window-close), returns None.

SPEC-056 - Login screen + create-account flow.

Design note: action functions (``_attempt_sign_in``, ``_attempt_create``)
and StringVars (``username_var`` etc.) are instance attributes so that
a programmatic driver (e.g. ``tests/test_login_gate_e2e.py``) can fill
fields and trigger actions without running ``mainloop`` or simulating
mouse events. ``_build_window`` constructs the window and renders the
current-mode form synchronously; ``run`` is ``_build_window`` + ``mainloop``.
"""

from __future__ import annotations

import tkinter as tk
from pathlib import Path
from tkinter import ttk
from typing import Optional

from .auth import (
    AuthError,
    DEFAULT_ACCOUNTS_PATH,
    authenticate,
    create_account,
    has_any_account,
)


class LoginGate:
    """Tk-driven login gate. Construct, call ``run()``, get a username or None.

    For programmatic testing: call ``_build_window()``, set the StringVar
    fields directly, and call the action methods (``_attempt_sign_in`` or
    ``_attempt_create``). The widget tree exists but ``mainloop`` is not
    running; that is fine for everything except actual user input events.
    """

    def __init__(self, accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> None:
        self.accounts_path = accounts_path
        self.result: Optional[str] = None
        self.root: Optional[tk.Tk] = None
        self.mode = "login"
        if not has_any_account(accounts_path=accounts_path):
            self.mode = "create_account"
        self.username_var: Optional[tk.StringVar] = None
        self.password_var: Optional[tk.StringVar] = None
        self.confirm_var: Optional[tk.StringVar] = None
        self.error_var: Optional[tk.StringVar] = None
        self.sign_in_button: Optional[ttk.Button] = None
        self.create_button: Optional[ttk.Button] = None
        self.switch_link: Optional[ttk.Label] = None

    def run(self) -> Optional[str]:
        self._build_window()
        assert self.root is not None
        self.root.mainloop()
        return self.result

    def _build_window(self) -> None:
        self.root = tk.Tk()
        self.root.title("Apeiron - Sign in")
        self.root.minsize(380, 260)
        try:
            self.root.attributes("-topmost", True)
        except tk.TclError:
            pass
        self.root.update_idletasks()
        w, h = 380, 260
        sw = self.root.winfo_screenwidth()
        sh = self.root.winfo_screenheight()
        self.root.geometry(f"{w}x{h}+{(sw - w) // 2}+{(sh - h) // 2}")
        self.root.bind("<Escape>", lambda _e: self._cancel())
        self.root.protocol("WM_DELETE_WINDOW", self._cancel)
        self._render()

    def _cancel(self) -> None:
        self.result = None
        if self.root is not None:
            try:
                self.root.destroy()
            except tk.TclError:
                pass
            self.root = None

    def _finish(self, username: str) -> None:
        self.result = username
        if self.root is not None:
            try:
                self.root.destroy()
            except tk.TclError:
                pass
            self.root = None

    def switch_mode(self, mode: str) -> None:
        """Switch between 'login' and 'create_account'. Re-renders the form."""
        if mode not in ("login", "create_account"):
            raise ValueError(f"unknown login-gate mode: {mode!r}")
        self.mode = mode
        self._render()

    def _attempt_sign_in(self, _event=None) -> None:
        """Validate + authenticate. On success, _finish; on failure, set error."""
        assert self.username_var is not None and self.password_var is not None
        assert self.error_var is not None
        username = self.username_var.get().strip()
        password = self.password_var.get()
        if not username or not password:
            self.error_var.set("Enter a username and password.")
            return
        if authenticate(username, password, accounts_path=self.accounts_path):
            self._finish(username)
        else:
            self.error_var.set("Incorrect username or password.")
            self.password_var.set("")

    def _attempt_create(self, _event=None) -> None:
        """Validate + create_account + auto-sign-in. On error, set error_var."""
        assert self.username_var is not None and self.password_var is not None
        assert self.confirm_var is not None and self.error_var is not None
        username = self.username_var.get().strip()
        password = self.password_var.get()
        confirm = self.confirm_var.get()
        if not username:
            self.error_var.set("Username cannot be empty.")
            return
        if not password:
            self.error_var.set("Password cannot be empty.")
            return
        if password != confirm:
            self.error_var.set("Passwords do not match.")
            return
        try:
            create_account(username, password, accounts_path=self.accounts_path)
        except AuthError as exc:
            self.error_var.set(str(exc))
            return
        self._finish(username)

    def _render(self) -> None:
        assert self.root is not None
        for child in list(self.root.winfo_children()):
            child.destroy()
        for binding in ("<Return>",):
            self.root.unbind(binding)
        self.username_var = None
        self.password_var = None
        self.confirm_var = None
        self.error_var = None
        self.sign_in_button = None
        self.create_button = None
        self.switch_link = None
        if self.mode == "login":
            self._render_login()
        else:
            self._render_create()

    def _render_login(self) -> None:
        assert self.root is not None
        frame = ttk.Frame(self.root, padding=20)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Apeiron", font=("TkDefaultFont", 14, "bold")).pack(pady=(0, 4))
        ttk.Label(frame, text="Sign in to continue").pack(pady=(0, 12))

        self.username_var = tk.StringVar()
        self.password_var = tk.StringVar()
        self.error_var = tk.StringVar()

        ttk.Label(frame, text="Username").pack(anchor="w")
        username_entry = ttk.Entry(frame, textvariable=self.username_var)
        username_entry.pack(fill="x")

        ttk.Label(frame, text="Password").pack(anchor="w", pady=(8, 0))
        password_entry = ttk.Entry(frame, textvariable=self.password_var, show="*")
        password_entry.pack(fill="x")

        ttk.Label(frame, textvariable=self.error_var, foreground="red").pack(pady=(8, 0))

        self.sign_in_button = ttk.Button(frame, text="Sign in", command=self._attempt_sign_in)
        self.sign_in_button.pack(pady=(12, 4))

        self.switch_link = ttk.Label(frame, text="Create new account", foreground="blue", cursor="hand2")
        self.switch_link.pack()
        self.switch_link.bind("<Button-1>", lambda _e: self.switch_mode("create_account"))

        self.root.bind("<Return>", self._attempt_sign_in)
        username_entry.focus_set()

    def _render_create(self) -> None:
        assert self.root is not None
        frame = ttk.Frame(self.root, padding=20)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Apeiron", font=("TkDefaultFont", 14, "bold")).pack(pady=(0, 4))
        ttk.Label(frame, text="Create a new account").pack(pady=(0, 12))

        self.username_var = tk.StringVar()
        self.password_var = tk.StringVar()
        self.confirm_var = tk.StringVar()
        self.error_var = tk.StringVar()

        ttk.Label(frame, text="Username").pack(anchor="w")
        username_entry = ttk.Entry(frame, textvariable=self.username_var)
        username_entry.pack(fill="x")

        ttk.Label(frame, text="Password").pack(anchor="w", pady=(6, 0))
        password_entry = ttk.Entry(frame, textvariable=self.password_var, show="*")
        password_entry.pack(fill="x")

        ttk.Label(frame, text="Confirm password").pack(anchor="w", pady=(6, 0))
        confirm_entry = ttk.Entry(frame, textvariable=self.confirm_var, show="*")
        confirm_entry.pack(fill="x")

        ttk.Label(frame, textvariable=self.error_var, foreground="red").pack(pady=(8, 0))

        self.create_button = ttk.Button(frame, text="Create", command=self._attempt_create)
        self.create_button.pack(pady=(12, 4))

        if has_any_account(accounts_path=self.accounts_path):
            self.switch_link = ttk.Label(frame, text="Back to sign in", foreground="blue", cursor="hand2")
            self.switch_link.pack()
            self.switch_link.bind("<Button-1>", lambda _e: self.switch_mode("login"))

        self.root.bind("<Return>", self._attempt_create)
        username_entry.focus_set()


def run_login_gate(accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> Optional[str]:
    """Run the gate. Returns the authenticated username on success, None on cancel."""
    gate = LoginGate(accounts_path=accounts_path)
    return gate.run()
