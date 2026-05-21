"""Tests for AuthGate — surface-independent password authentication.

Covers every verb: authenticate (ok / wrong-password / empty-input),
has_any_account, list_accounts. Uses a real on-disk accounts store
(scrypt-hashed) — the same fixture pattern test_login_gate_e2e.py uses
for the panel surface, minus Streamlit.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from engine import actions as engine_actions
from engine.core import Engine
from tools.workflow import auth as auth_module


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def engine_with_auth_gate(tmp_path: Path) -> Engine:
    accounts_path = tmp_path / "accounts.json"
    # Pre-create one account so the authenticate-success path has
    # something to match against.
    auth_module.create_account(
        "alice", "correcthorse", accounts_path=accounts_path
    )
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "auth_gate_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [
            {"id":"auth_gate_main","type":"AuthGate","params":{}}
          ]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    engine.cache["__workflow__"] = {"accounts_path": accounts_path}
    return engine


# ---------- authenticate ----------

def test_authenticate_success(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "authenticate",
        payload={"username": "alice", "password": "correcthorse"},
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_authenticate"]["ok"] is True
    assert view["last_authenticate"]["username"] == "alice"


def test_authenticate_wrong_password(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "authenticate",
        payload={"username": "alice", "password": "wrong"},
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_authenticate"]["ok"] is False
    assert "incorrect" in view["last_authenticate"]["reason"].lower()


def test_authenticate_unknown_user(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "authenticate",
        payload={"username": "nobody", "password": "anything"},
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_authenticate"]["ok"] is False


def test_authenticate_empty_username(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "authenticate",
        payload={"username": "  ", "password": "anything"},
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_authenticate"]["ok"] is False
    assert "username required" in view["last_authenticate"]["reason"]


def test_authenticate_empty_password(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "authenticate",
        payload={"username": "alice", "password": ""},
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_authenticate"]["ok"] is False
    assert "password required" in view["last_authenticate"]["reason"]


# ---------- has_any_account ----------

def test_has_any_account_true(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "has_any_account", payload={}
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_has_any_account"]["ok"] is True
    assert view["last_has_any_account"]["present"] is True


def test_has_any_account_false_on_empty_store(tmp_path: Path) -> None:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "auth_gate_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [{"id":"auth_gate_main","type":"AuthGate","params":{}}]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    engine.cache["__workflow__"] = {"accounts_path": tmp_path / "empty.json"}
    engine_actions.dispatch_action(
        engine, "auth_gate_main", "has_any_account", payload={}
    )
    view = engine_actions.get_view_state(engine, "auth_gate_main")
    assert view["last_has_any_account"]["present"] is False


# ---------- list_accounts ----------

def test_list_accounts_returns_names(engine_with_auth_gate: Engine) -> None:
    engine_actions.dispatch_action(
        engine_with_auth_gate, "auth_gate_main", "list_accounts", payload={}
    )
    view = engine_actions.get_view_state(engine_with_auth_gate, "auth_gate_main")
    assert view["last_list_accounts"]["ok"] is True
    assert "alice" in view["last_list_accounts"]["accounts"]


# ---------- error paths ----------

def test_missing_accounts_path_returns_clean_error(tmp_path: Path) -> None:
    engine = Engine(root_dir=REPO_ROOT)
    engine.discover()
    scene = tmp_path / "scene.json"
    scene.write_text(
        """{
          "root": "auth_gate_main",
          "view": {"position":[0,0,5],"look_at":[0,0,0],"width":64,"height":64,"fov_y_radians":0.6},
          "nodes": [{"id":"auth_gate_main","type":"AuthGate","params":{}}]
        }""",
        encoding="utf-8",
    )
    engine.load_scene(scene)
    # No __workflow__ singleton.
    engine_actions.dispatch_action(
        engine, "auth_gate_main", "authenticate",
        payload={"username": "x", "password": "y"},
    )
    view = engine_actions.get_view_state(engine, "auth_gate_main")
    assert "accounts_path" in view["last_error"]
