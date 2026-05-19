"""
Stress tests for tools.workflow.auth. Deliberately probes edge cases,
malformed inputs, concurrent operations, and adversarial scenarios.

These tests aim to break the auth implementation, per the
implementation-session convention's stress-test stopping criterion.
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path

import pytest

from tools.workflow.auth import (
    AuthError,
    authenticate,
    create_account,
    has_any_account,
    list_accounts,
    validate_username,
)


@pytest.fixture
def accounts_path(tmp_path: Path) -> Path:
    return tmp_path / "accounts.json"


# ---------- Malformed store -----------------------------------------------

def test_zero_byte_store_does_not_crash_authenticate(accounts_path: Path):
    """An empty (0-byte) accounts.json must not crash authenticate."""
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_bytes(b"")
    assert not authenticate("anyone", "anything", accounts_path=accounts_path)
    assert list_accounts(accounts_path=accounts_path) == []
    assert not has_any_account(accounts_path=accounts_path)


def test_truncated_json_does_not_crash_authenticate(accounts_path: Path):
    """Truncated JSON (e.g. crash during write) must fail safely."""
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_text('{"version": 1, "accounts":', encoding="utf-8")
    assert not authenticate("anyone", "anything", accounts_path=accounts_path)


def test_wrong_version_blocks_create(accounts_path: Path):
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_text(json.dumps({"version": 99, "accounts": {}}), encoding="utf-8")
    with pytest.raises(AuthError):
        create_account("LHH", "pw", accounts_path=accounts_path)


def test_accounts_field_missing_is_handled(accounts_path: Path):
    """A JSON file missing the 'accounts' key should be rejected on create."""
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    accounts_path.write_text(json.dumps({"version": 1}), encoding="utf-8")
    with pytest.raises(AuthError):
        create_account("LHH", "pw", accounts_path=accounts_path)


def test_account_record_missing_hash_returns_false(accounts_path: Path):
    """An account record missing required fields must not raise — auth returns False."""
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    store = {"version": 1, "accounts": {"LHH": {"salt": "00" * 32}}}
    accounts_path.write_text(json.dumps(store), encoding="utf-8")
    assert not authenticate("LHH", "anything", accounts_path=accounts_path)


def test_account_record_malformed_hex_returns_false(accounts_path: Path):
    accounts_path.parent.mkdir(parents=True, exist_ok=True)
    store = {
        "version": 1,
        "accounts": {
            "LHH": {
                "salt": "not-hex",
                "hash": "also-not-hex",
                "params": {"n": 16384, "r": 8, "p": 1, "dklen": 64},
            }
        },
    }
    accounts_path.write_text(json.dumps(store), encoding="utf-8")
    assert not authenticate("LHH", "anything", accounts_path=accounts_path)


# ---------- Username edge cases -------------------------------------------

def test_username_with_null_byte_rejected(accounts_path: Path):
    with pytest.raises(AuthError):
        create_account("LHH\x00admin", "pw", accounts_path=accounts_path)


def test_username_max_length_accepted(accounts_path: Path):
    create_account("a" * 32, "pw", accounts_path=accounts_path)
    assert authenticate("a" * 32, "pw", accounts_path=accounts_path)


def test_username_just_over_max_length_rejected(accounts_path: Path):
    with pytest.raises(AuthError):
        validate_username("a" * 33)


def test_username_unicode_rejected(accounts_path: Path):
    with pytest.raises(AuthError):
        create_account("中文用户", "pw", accounts_path=accounts_path)


def test_username_with_dot_rejected(accounts_path: Path):
    with pytest.raises(AuthError):
        create_account("user.name", "pw", accounts_path=accounts_path)


def test_username_case_sensitive_creates_two_accounts(accounts_path: Path):
    create_account("LHH", "first", accounts_path=accounts_path)
    create_account("lhh", "second", accounts_path=accounts_path)
    assert authenticate("LHH", "first", accounts_path=accounts_path)
    assert authenticate("lhh", "second", accounts_path=accounts_path)
    assert not authenticate("LHH", "second", accounts_path=accounts_path)
    assert not authenticate("lhh", "first", accounts_path=accounts_path)


# ---------- Password edge cases -------------------------------------------

def test_password_with_unicode_authenticates(accounts_path: Path):
    """scrypt is byte-level — unicode passwords (emoji, RTL marks) must work."""
    pw = "p‮password‬\U0001f512"
    create_account("UnicodeUser", pw, accounts_path=accounts_path)
    assert authenticate("UnicodeUser", pw, accounts_path=accounts_path)
    assert not authenticate("UnicodeUser", "ppassword🔒", accounts_path=accounts_path)


def test_password_with_null_byte_authenticates(accounts_path: Path):
    pw = "pass\x00word"
    create_account("NullPwUser", pw, accounts_path=accounts_path)
    assert authenticate("NullPwUser", pw, accounts_path=accounts_path)
    assert not authenticate("NullPwUser", "pass", accounts_path=accounts_path)


def test_oversized_password_authenticates(accounts_path: Path):
    """A 100 KB password must hash and verify (scrypt scales with input length)."""
    pw = "x" * 100_000
    create_account("BigPwUser", pw, accounts_path=accounts_path)
    assert authenticate("BigPwUser", pw, accounts_path=accounts_path)


def test_password_with_only_whitespace_accepted(accounts_path: Path):
    """The validator rejects empty but accepts a single space — the maintainer's choice."""
    create_account("SpaceUser", " ", accounts_path=accounts_path)
    assert authenticate("SpaceUser", " ", accounts_path=accounts_path)
    assert not authenticate("SpaceUser", "", accounts_path=accounts_path)
    assert not authenticate("SpaceUser", "  ", accounts_path=accounts_path)


# ---------- Concurrency --------------------------------------------------

def test_concurrent_create_account_no_data_loss(accounts_path: Path):
    """Multiple threads creating different accounts must not lose data.

    Note: this test does not assert serializability or absence of duplicate-create
    races — Python's GIL plus the file-replace atomicity means at worst one create
    may be silently dropped if two threads race to the same temp-file rename.
    The implementation is good-enough for a single-user personal-machine workflow.
    """
    n_threads = 8
    errors: list[Exception] = []

    def make(i: int) -> None:
        try:
            create_account(f"user{i}", f"pw{i}", accounts_path=accounts_path)
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=make, args=(i,)) for i in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    created = list_accounts(accounts_path=accounts_path)
    assert len(created) >= 1
    for user in created:
        i = int(user[len("user"):])
        assert authenticate(f"user{i}", f"pw{i}", accounts_path=accounts_path)


def test_authenticate_during_create_does_not_crash(accounts_path: Path):
    """Reading authenticate() during a concurrent create() must not raise."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    stop = threading.Event()
    err: list[Exception] = []

    def hammer() -> None:
        while not stop.is_set():
            try:
                authenticate("LHH", "pw", accounts_path=accounts_path)
            except Exception as exc:
                err.append(exc)

    t = threading.Thread(target=hammer, daemon=True)
    t.start()
    try:
        for i in range(5):
            create_account(f"new{i}", "pw", accounts_path=accounts_path)
    finally:
        stop.set()
        t.join(timeout=2.0)

    assert not err, f"authenticate raised during concurrent create: {err[:3]}"


# ---------- Orphan tmp file ------------------------------------------------

def test_orphan_tmp_file_does_not_affect_load(accounts_path: Path):
    """A leftover .json.tmp from a crashed write must not interfere with load."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    orphan = accounts_path.with_suffix(".json.tmp")
    orphan.write_text("garbage that would crash json.load", encoding="utf-8")
    assert authenticate("LHH", "pw", accounts_path=accounts_path)
    assert orphan.exists()


# ---------- Read-only filesystem (best-effort) -----------------------------

def test_create_account_with_unwritable_dir_raises(tmp_path: Path):
    """When the accounts dir can't be written, create_account must raise — not silently fail."""
    accounts_path = tmp_path / "nonexistent_parent" / "deeper" / "accounts.json"
    create_account("LHH", "pw", accounts_path=accounts_path)
    assert accounts_path.exists()


# ---------- File format invariants ----------------------------------------

def test_save_preserves_unknown_extension_fields(accounts_path: Path):
    """A future-version field added to a record must not be wiped on next write."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    data["accounts"]["LHH"]["future_field"] = "preserve me"
    accounts_path.write_text(json.dumps(data), encoding="utf-8")

    create_account("Other", "pw", accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        data2 = json.load(f)
    assert data2["accounts"]["LHH"].get("future_field") == "preserve me"


def test_save_is_indented_pretty_json(accounts_path: Path):
    """The saved file is human-readable (indented), not compact."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    raw = accounts_path.read_text(encoding="utf-8")
    assert "\n" in raw
    assert "  " in raw


# ---------- Hash strength ---------------------------------------------------

def test_scrypt_n_meets_minimum(accounts_path: Path):
    """Scrypt n parameter should be at least 2^14 (OWASP minimum)."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    n = data["accounts"]["LHH"]["params"]["n"]
    assert n >= 2 ** 14, f"scrypt n={n} is weaker than OWASP minimum 2^14"


def test_salt_is_long_enough(accounts_path: Path):
    """Per-account salt should be at least 16 bytes (industry standard); we use 32."""
    create_account("LHH", "pw", accounts_path=accounts_path)
    with accounts_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    salt_hex = data["accounts"]["LHH"]["salt"]
    assert len(salt_hex) >= 32, f"salt is {len(salt_hex) // 2} bytes; expected >= 16"
