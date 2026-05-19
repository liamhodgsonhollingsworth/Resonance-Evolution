"""
Native Tk login window for Apeiron. Pre-engine authentication gate.

Shows a sign-in form when accounts exist, or a create-account form when
the store is empty (the bootstrap path). The "Create new account" link
switches the form mode; the "Back to sign in" link goes back. On
successful sign-in (or successful create-then-auto-sign-in) the window
closes and the authenticated username is returned. On cancel (Escape or
window-close), returns None.

SPEC-056 - Login screen + create-account flow.
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
    """Tk-driven login gate. Construct, call ``run()``, get a username or None."""

    def __init__(self, accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> None:
        self.accounts_path = accounts_path
        self.result: Optional[str] = None
        self.root: Optional[tk.Tk] = None
        self.mode = "login"
        if not has_any_account(accounts_path=accounts_path):
            self.mode = "create_account"

    def run(self) -> Optional[str]:
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
        self.root.mainloop()
        return self.result

    def _cancel(self) -> None:
        self.result = None
        if self.root is not None:
            self.root.destroy()
            self.root = None

    def _finish(self, username: str) -> None:
        self.result = username
        if self.root is not None:
            self.root.destroy()
            self.root = None

    def _render(self) -> None:
        assert self.root is not None
        for child in list(self.root.winfo_children()):
            child.destroy()
        for binding in ("<Return>",):
            self.root.unbind(binding)
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

        username_var = tk.StringVar()
        password_var = tk.StringVar()
        error_var = tk.StringVar()

        ttk.Label(frame, text="Username").pack(anchor="w")
        username_entry = ttk.Entry(frame, textvariable=username_var)
        username_entry.pack(fill="x")

        ttk.Label(frame, text="Password").pack(anchor="w", pady=(8, 0))
        password_entry = ttk.Entry(frame, textvariable=password_var, show="*")
        password_entry.pack(fill="x")

        ttk.Label(frame, textvariable=error_var, foreground="red").pack(pady=(8, 0))

        def attempt_sign_in(_event=None):
            username = username_var.get().strip()
            password = password_var.get()
            if not username or not password:
                error_var.set("Enter a username and password.")
                return
            if authenticate(username, password, accounts_path=self.accounts_path):
                self._finish(username)
            else:
                error_var.set("Incorrect username or password.")
                password_var.set("")
                password_entry.focus_set()

        ttk.Button(frame, text="Sign in", command=attempt_sign_in).pack(pady=(12, 4))

        def switch_to_create():
            self.mode = "create_account"
            self._render()

        link = ttk.Label(frame, text="Create new account", foreground="blue", cursor="hand2")
        link.pack()
        link.bind("<Button-1>", lambda _e: switch_to_create())

        self.root.bind("<Return>", attempt_sign_in)
        username_entry.focus_set()

    def _render_create(self) -> None:
        assert self.root is not None
        frame = ttk.Frame(self.root, padding=20)
        frame.pack(fill="both", expand=True)

        ttk.Label(frame, text="Apeiron", font=("TkDefaultFont", 14, "bold")).pack(pady=(0, 4))
        ttk.Label(frame, text="Create a new account").pack(pady=(0, 12))

        username_var = tk.StringVar()
        password_var = tk.StringVar()
        confirm_var = tk.StringVar()
        error_var = tk.StringVar()

        ttk.Label(frame, text="Username").pack(anchor="w")
        username_entry = ttk.Entry(frame, textvariable=username_var)
        username_entry.pack(fill="x")

        ttk.Label(frame, text="Password").pack(anchor="w", pady=(6, 0))
        password_entry = ttk.Entry(frame, textvariable=password_var, show="*")
        password_entry.pack(fill="x")

        ttk.Label(frame, text="Confirm password").pack(anchor="w", pady=(6, 0))
        confirm_entry = ttk.Entry(frame, textvariable=confirm_var, show="*")
        confirm_entry.pack(fill="x")

        ttk.Label(frame, textvariable=error_var, foreground="red").pack(pady=(8, 0))

        def attempt_create(_event=None):
            username = username_var.get().strip()
            password = password_var.get()
            confirm = confirm_var.get()
            if not username:
                error_var.set("Username cannot be empty.")
                return
            if not password:
                error_var.set("Password cannot be empty.")
                return
            if password != confirm:
                error_var.set("Passwords do not match.")
                return
            try:
                create_account(username, password, accounts_path=self.accounts_path)
            except AuthError as exc:
                error_var.set(str(exc))
                return
            self._finish(username)

        ttk.Button(frame, text="Create", command=attempt_create).pack(pady=(12, 4))

        if has_any_account(accounts_path=self.accounts_path):
            def switch_to_login():
                self.mode = "login"
                self._render()

            link = ttk.Label(frame, text="Back to sign in", foreground="blue", cursor="hand2")
            link.pack()
            link.bind("<Button-1>", lambda _e: switch_to_login())

        self.root.bind("<Return>", attempt_create)
        username_entry.focus_set()


def run_login_gate(accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> Optional[str]:
    """Run the gate. Returns the authenticated username on success, None on cancel."""
    gate = LoginGate(accounts_path=accounts_path)
    return gate.run()
