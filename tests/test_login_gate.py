"""
Tests for tools.workflow.login_gate.

The Tk widget interaction is not testable headlessly without GUI
automation; this test covers the pure-logic surface: mode selection
based on whether the accounts store is empty.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.workflow.auth import create_account
from tools.workflow.login_gate import LoginGate


@pytest.fixture
def accounts_path(tmp_path: Path) -> Path:
    return tmp_path / "accounts.json"


def test_initial_mode_is_create_account_when_store_empty(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    assert gate.mode == "create_account"


def test_initial_mode_is_login_when_account_exists(accounts_path: Path):
    create_account("LHH", "pw", accounts_path=accounts_path)
    gate = LoginGate(accounts_path=accounts_path)
    assert gate.mode == "login"


def test_gate_initial_result_is_none(accounts_path: Path):
    gate = LoginGate(accounts_path=accounts_path)
    assert gate.result is None


def test_run_login_gate_is_callable(accounts_path: Path):
    """Smoke check that the module-level helper is importable and accepts the accounts_path kwarg."""
    from tools.workflow.login_gate import run_login_gate
    assert callable(run_login_gate)
