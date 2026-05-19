"""
End-to-end tests that programmatically drive the LoginGate without
mainloop. This is the GUI-driver test tool the implementation-session
convention names: build a tool to test the GUI itself, iterate on it.

Each test constructs the gate via ``_build_window`` (which creates the
Tk root + widgets synchronously) and then calls the action methods
directly with StringVars set to the test inputs. The gate's success
path calls ``root.destroy()``; the gate's failure path sets an error
in the error StringVar, which the test reads.

Skipped on systems where ``tk.Tk()`` cannot construct (no display).
"""

from __future__ import annotations

from pathlib import Path

import pytest

tk = pytest.importorskip("tkinter")

from tools.workflow.auth import authenticate, create_account, has_any_account
from tools.workflow.login_gate import LoginGate


def _build_or_skip(gate: LoginGate) -> None:
    """Construct the Tk widget tree, or skip the test if Tk isn't usable.

    The pytestmark + module-level _can_open_display pattern caused
    ``tk.Tk()`` to fail on the first test in this file under some Python
    installs (the warmup destroyed Tcl state in a way that broke the next
    init). Per-test try/except is more robust.
    """
    try:
        gate._build_window()
    except tk.TclError as exc:
        pytest.skip(f"Tk display unavailable in this environment: {exc}")


@pytest.fixture
def accounts_path(tmp_path: Path) -> Path:
    return tmp_path / "accounts.json"


def test_create_account_flow_persists_and_authenticates(accounts_path: Path):
    """The bootstrap create-account flow stores LHH and signs them in."""
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    assert gate.mode == "create_account"
    gate.username_var.set("LHH")
    gate.password_var.set("test-password-1")
    gate.confirm_var.set("test-password-1")
    gate._attempt_create()
    assert gate.result == "LHH"
    assert gate.root is None
    assert authenticate("LHH", "test-password-1", accounts_path=accounts_path)


def test_create_account_mismatched_confirm_shows_error_without_saving(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("LHH")
    gate.password_var.set("first")
    gate.confirm_var.set("second")
    gate._attempt_create()
    assert gate.result is None
    assert "Passwords do not match" in gate.error_var.get()
    assert not accounts_path.exists() or not has_any_account(accounts_path=accounts_path)
    gate._cancel()


def test_create_account_empty_username_shows_error(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("")
    gate.password_var.set("p")
    gate.confirm_var.set("p")
    gate._attempt_create()
    assert gate.result is None
    assert "Username cannot be empty" in gate.error_var.get()
    gate._cancel()


def test_create_account_empty_password_shows_error(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("LHH")
    gate.password_var.set("")
    gate.confirm_var.set("")
    gate._attempt_create()
    assert gate.result is None
    assert "Password cannot be empty" in gate.error_var.get()
    gate._cancel()


def test_duplicate_username_create_shows_error(accounts_path: Path):
    create_account("LHH", "pre-existing", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.switch_mode("create_account")
    gate.username_var.set("LHH")
    gate.password_var.set("new")
    gate.confirm_var.set("new")
    gate._attempt_create()
    assert gate.result is None
    assert "already exists" in gate.error_var.get()
    gate._cancel()


def test_sign_in_flow_with_correct_credentials(accounts_path: Path):
    create_account("LHH", "the-real-password", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    assert gate.mode == "login"
    gate.username_var.set("LHH")
    gate.password_var.set("the-real-password")
    gate._attempt_sign_in()
    assert gate.result == "LHH"
    assert gate.root is None


def test_sign_in_flow_with_wrong_password_shows_error(accounts_path: Path):
    create_account("LHH", "real", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("LHH")
    gate.password_var.set("wrong")
    gate._attempt_sign_in()
    assert gate.result is None
    assert "Incorrect" in gate.error_var.get()
    assert gate.password_var.get() == ""
    gate._cancel()


def test_sign_in_flow_with_unknown_username_shows_error(accounts_path: Path):
    create_account("LHH", "pw", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("UnknownUser")
    gate.password_var.set("anything")
    gate._attempt_sign_in()
    assert gate.result is None
    assert "Incorrect" in gate.error_var.get()
    gate._cancel()


def test_mode_switch_clears_fields(accounts_path: Path):
    create_account("LHH", "pw", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    assert gate.mode == "login"
    gate.username_var.set("typed-but-switched")
    gate.password_var.set("typed-but-switched")
    gate.switch_mode("create_account")
    assert gate.mode == "create_account"
    assert gate.username_var.get() == ""
    assert gate.password_var.get() == ""
    assert gate.confirm_var.get() == ""
    gate._cancel()


def test_unicode_username_is_rejected(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("中文")
    gate.password_var.set("p")
    gate.confirm_var.set("p")
    gate._attempt_create()
    assert gate.result is None
    assert "1-32" in gate.error_var.get() or "letters" in gate.error_var.get()
    gate._cancel()


def test_whitespace_username_is_stripped_then_validated(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("  LHH  ")
    gate.password_var.set("pw")
    gate.confirm_var.set("pw")
    gate._attempt_create()
    assert gate.result == "LHH"


def test_oversized_password_creates_and_authenticates(accounts_path: Path):
    """A 10 KB password must still hash and authenticate (slower but works)."""
    long_pw = "x" * 10_000
    gate = LoginGate(accounts_path=accounts_path)
    _build_or_skip(gate)
    gate.username_var.set("BigUser")
    gate.password_var.set(long_pw)
    gate.confirm_var.set(long_pw)
    gate._attempt_create()
    assert gate.result == "BigUser"
    assert authenticate("BigUser", long_pw, accounts_path=accounts_path)
    assert not authenticate("BigUser", long_pw + "x", accounts_path=accounts_path)
