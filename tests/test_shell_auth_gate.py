"""
Tests for the shell.main() auth gate integration.

Verifies that --skip-auth bypasses the gate, and that main() short-circuits
with a cancel exit code when the gate returns None.
"""

from __future__ import annotations

import io
import sys
from pathlib import Path

import pytest

from tools.workflow import shell as shell_module


def test_main_with_skip_auth_does_not_call_login_gate(monkeypatch, tmp_path: Path):
    """--skip-auth must prevent any import or invocation of the login gate."""

    def boom(*_args, **_kwargs):
        raise AssertionError("login gate should not be invoked when --skip-auth is set")

    monkeypatch.setattr(
        "tools.workflow.login_gate.run_login_gate", boom, raising=False
    )

    def fake_shell_run(self):
        return None

    monkeypatch.setattr(shell_module.Shell, "run", fake_shell_run)
    monkeypatch.setattr(
        shell_module.Shell, "ensure_default_workflow_mgmt_session", lambda self: None
    )

    exit_code = shell_module.main(
        [
            "--skip-auth",
            "--no-watch",
            "--no-default-session",
            "--state-dir",
            str(tmp_path / "workflow_state"),
            "--accounts-path",
            str(tmp_path / "accounts.json"),
        ]
    )
    assert exit_code == 0


def test_main_with_gate_cancellation_returns_nonzero(monkeypatch, tmp_path: Path):
    """When the gate returns None (cancel), main() exits without booting the engine."""

    monkeypatch.setattr(
        "tools.workflow.login_gate.run_login_gate", lambda accounts_path: None
    )

    sentinel = {"engine_constructed": False}

    real_engine_cls = shell_module.Engine

    class TrackedEngine(real_engine_cls):
        def __init__(self, *a, **kw):
            sentinel["engine_constructed"] = True
            super().__init__(*a, **kw)

    monkeypatch.setattr(shell_module, "Engine", TrackedEngine)

    err_buf = io.StringIO()
    monkeypatch.setattr(sys, "stderr", err_buf)

    exit_code = shell_module.main(
        [
            "--no-watch",
            "--no-default-session",
            "--state-dir",
            str(tmp_path / "workflow_state"),
            "--accounts-path",
            str(tmp_path / "accounts.json"),
        ]
    )

    assert exit_code == 1
    assert not sentinel["engine_constructed"]
    assert "Sign-in cancelled" in err_buf.getvalue()


def test_main_with_gate_success_passes_user_to_shell(monkeypatch, tmp_path: Path):
    """A successful gate must place current_user on the Shell instance for downstream use."""

    monkeypatch.setattr(
        "tools.workflow.login_gate.run_login_gate", lambda accounts_path: "LHH"
    )

    captured = {}

    def fake_shell_run(self):
        captured["current_user"] = self.current_user
        return None

    monkeypatch.setattr(shell_module.Shell, "run", fake_shell_run)
    monkeypatch.setattr(
        shell_module.Shell, "ensure_default_workflow_mgmt_session", lambda self: None
    )

    exit_code = shell_module.main(
        [
            "--no-watch",
            "--no-default-session",
            "--state-dir",
            str(tmp_path / "workflow_state"),
            "--accounts-path",
            str(tmp_path / "accounts.json"),
        ]
    )

    assert exit_code == 0
    assert captured["current_user"] == "LHH"
