"""
Tests for tools.workflow.auth - account store + authentication.

Covers: validation rules, create_account persistence, scrypt hash
correctness, salt-uniqueness, duplicate-username rejection, unknown-user
authentication (must run the KDF to equalize timing), and corrupted-store
fallthrough behavior.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from tools.workflow.auth import (
    AuthError,
    authenticate,
    create_account,
    has_any_account,
    list_accounts,
    validate_password,
    validate_username,
)


@pytest.fixture
def accounts_path(tmp_path: Path) -> Path:
    return tmp_path / "accounts.json"


def test_validate_username_accepts_alphanumeric_and_underscore():
    validate_username("LHH")
    validate_username("user_42")
    validate_username("a")
    validate_username("A_long_username_123")


def test_validate_username_rejects_empty():
    with pytest.raises(AuthError):
        validate_username("")


def test_validate_username_rejects_too_long():
    with pytest.raises(AuthError):
        validate_username("a" * 33)


def test_validate_username_rejects_invalid_chars():
    with pytest.raises(AuthError):
        validate_username("LHH ")
    with pytest.raises(AuthError):
        validate_username("user-with-dash")
    with pytest.raises(AuthError):
        validate_username("user@domain")
    with pytest.raises(AuthError):
        validate_username("name with space")


def test_validate_password_accepts_non_empty():
    validate_password("a")
    validate_password("a very long password with spaces and !@#$%")


def test_validate_password_rejects_empty():
    with pytest.raises(AuthError):
        validate_password("")


def test_create_account_persists_and_can_authenticate(accounts_path: Path):
    create_account("LHH", "secret-password", accounts_path=accounts_path)
    assert accounts_path.exists()
    assert authenticate("LHH", "secret-password", accounts_path=accounts_path)


def test_create_account_then_wrong_password_returns_false(accounts_path: Path):
    create_account("LHH", "right", accounts_path=accounts_path)
    assert not authenticate("LHH", "wrong", accounts_path=accounts_path)


def test_create_account_rejects_duplicate_username(accounts_path: Path):
    create_account("LHH", "pw1", accounts_path=accounts_path)
    with pytest.raises(AuthError):
        create_account("LHH", "pw2", accounts_path=accounts_path)


def test_create_account_rejects_invalid_username(accounts_path: Path):
    with pytest.raises(AuthError):
        create_account("user with space", "pw", accounts_path=accounts_path)


def test_create_account_rejects_empty_password(accounts_path: Path):
    with pytest.raises(AuthError):
        create_account("LHH", "", accounts_path=accounts_path)


def test_authenticate_rejects_unknown_username(accounts_path: Path):
    create_account("LHH", "pw", accounts_path=accounts_path)
    assert not authenticate("Other", "pw", accounts_path=accounts_path)


def test_authenticate_against_missing_store_returns_false(accounts_path: Path):
    assert not authenticate("anyone", "anything", accounts_path=accounts_path)


def test_stored_hash_is_not_cleartext(accounts_path: Path):
    password = "the-actual-password-text"
    create_account("LHH", password, accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        contents = f.read()
    assert password not in contents


def test_each_account_has_unique_salt_and_hash(accounts_path: Path):
    create_account("user1", "shared-password", accounts_path=accounts_path)
    create_account("user2", "shared-password", accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    salt1 = data["accounts"]["user1"]["salt"]
    salt2 = data["accounts"]["user2"]["salt"]
    hash1 = data["accounts"]["user1"]["hash"]
    hash2 = data["accounts"]["user2"]["hash"]
    assert salt1 != salt2
    assert hash1 != hash2


def test_list_accounts(accounts_path: Path):
    assert list_accounts(accounts_path=accounts_path) == []
    create_account("LHH", "pw", accounts_path=accounts_path)
    create_account("Other", "pw", accounts_path=accounts_path)
    assert list_accounts(accounts_path=accounts_path) == ["LHH", "Other"]


def test_has_any_account(accounts_path: Path):
    assert not has_any_account(accounts_path=accounts_path)
    create_account("LHH", "pw", accounts_path=accounts_path)
    assert has_any_account(accounts_path=accounts_path)


def test_unknown_user_auth_still_runs_kdf(accounts_path: Path):
    """Unknown-user auth must invoke the KDF to keep timing constant.

    scrypt at n=2^14 takes >5ms on any modern machine. If the unknown-user
    path short-circuits, this elapsed time would be <1ms, revealing that
    the username does not exist via timing analysis.
    """
    t0 = time.perf_counter()
    assert not authenticate("UnknownUser", "anything", accounts_path=accounts_path)
    elapsed_ms = (time.perf_counter() - t0) * 1000
    assert elapsed_ms > 5, (
        f"Unknown-user auth took {elapsed_ms:.2f}ms - expected >5ms (scrypt). "
        "Short-circuit detected; this would reveal username existence via timing."
    )


def test_corrupt_store_is_handled_gracefully(accounts_path: Path):
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_text("not json {", encoding="utf-8")
    assert not authenticate("LHH", "anything", accounts_path=accounts_path)
    assert list_accounts(accounts_path=accounts_path) == []
    assert not has_any_account(accounts_path=accounts_path)


def test_wrong_version_store_raises_on_create(accounts_path: Path):
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_text(
        json.dumps({"version": 99, "accounts": {}}), encoding="utf-8"
    )
    with pytest.raises(AuthError):
        create_account("LHH", "pw", accounts_path=accounts_path)
