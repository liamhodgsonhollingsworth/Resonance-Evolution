"""
Account storage and password verification for Apeiron.

Stores accounts in a gitignored JSON file (default: ``state/accounts.json``).
Passwords are hashed with ``hashlib.scrypt`` plus a per-account 32-byte
random salt; cleartext passwords never persist. Authentication runs the
KDF on every call (including for unknown usernames) so timing does not
reveal whether the username exists.

SPEC-055 — Username/password authentication for Apeiron.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


DEFAULT_ACCOUNTS_PATH = Path("state/accounts.json")

SCRYPT_N = 2 ** 14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 64
SCRYPT_SALT_BYTES = 32

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{1,32}$")


class AuthError(Exception):
    """Raised when account validation or store-shape checks fail. Auth-failure (wrong password) is signalled by ``authenticate`` returning False rather than raising."""


@dataclass
class Account:
    username: str
    salt_hex: str
    hash_hex: str
    params: dict
    created_at: str


def _default_params() -> dict:
    return {"n": SCRYPT_N, "r": SCRYPT_R, "p": SCRYPT_P, "dklen": SCRYPT_DKLEN}


def _hash_password(password: str, salt: bytes, params: dict) -> bytes:
    return hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=params["n"],
        r=params["r"],
        p=params["p"],
        dklen=params["dklen"],
    )


def _load_store(path: Path) -> dict:
    if not path.exists():
        return {"version": 1, "accounts": {}}
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("version") != 1:
        raise AuthError(f"Unsupported accounts.json version: {data.get('version')!r}")
    if "accounts" not in data or not isinstance(data["accounts"], dict):
        raise AuthError("accounts.json is missing or malformed accounts dict")
    return data


def _save_store(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    # Windows can raise PermissionError on os.replace if a concurrent reader has
    # the destination open at the moment of the rename. POSIX allows
    # rename-over-open-file; Windows does not. Retry with short backoff so the
    # race resolves naturally (caller-visible behavior matches POSIX).
    last_exc: Optional[Exception] = None
    for attempt in range(10):
        try:
            os.replace(tmp, path)
            return
        except PermissionError as exc:
            last_exc = exc
            time.sleep(0.005 * (attempt + 1))
    raise last_exc if last_exc else OSError("os.replace failed without an exception")


def validate_username(username: str) -> None:
    if not isinstance(username, str) or not USERNAME_RE.match(username):
        raise AuthError(
            "Username must be 1-32 characters of letters, digits, or underscore."
        )


def validate_password(password: str) -> None:
    if not isinstance(password, str) or len(password) < 1:
        raise AuthError("Password cannot be empty.")


def create_account(
    username: str,
    password: str,
    *,
    accounts_path: Path = DEFAULT_ACCOUNTS_PATH,
) -> Account:
    validate_username(username)
    validate_password(password)
    store = _load_store(accounts_path)
    if username in store["accounts"]:
        raise AuthError(f"Username {username!r} already exists.")
    salt = secrets.token_bytes(SCRYPT_SALT_BYTES)
    params = _default_params()
    digest = _hash_password(password, salt, params)
    record = {
        "salt": salt.hex(),
        "hash": digest.hex(),
        "params": params,
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    store["accounts"][username] = record
    _save_store(accounts_path, store)
    return Account(
        username=username,
        salt_hex=record["salt"],
        hash_hex=record["hash"],
        params=params,
        created_at=record["created_at"],
    )


def authenticate(
    username: str,
    password: str,
    *,
    accounts_path: Path = DEFAULT_ACCOUNTS_PATH,
) -> bool:
    """
    Verify (username, password) against the store. Returns True iff the
    record exists and the password's scrypt digest matches.

    Runs the KDF on every call — including when the username is unknown —
    so timing does not leak username existence.
    """
    try:
        store = _load_store(accounts_path)
    except (AuthError, FileNotFoundError, json.JSONDecodeError):
        store = {"version": 1, "accounts": {}}
    record = store["accounts"].get(username)
    if record is None:
        dummy_salt = b"\x00" * SCRYPT_SALT_BYTES
        _hash_password(password, dummy_salt, _default_params())
        return False
    try:
        salt = bytes.fromhex(record["salt"])
        expected = bytes.fromhex(record["hash"])
        params = record.get("params", _default_params())
    except (KeyError, ValueError):
        return False
    candidate = _hash_password(password, salt, params)
    return hmac.compare_digest(candidate, expected)


def list_accounts(*, accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> List[str]:
    try:
        store = _load_store(accounts_path)
    except (AuthError, FileNotFoundError, json.JSONDecodeError):
        return []
    return sorted(store["accounts"].keys())


def has_any_account(*, accounts_path: Path = DEFAULT_ACCOUNTS_PATH) -> bool:
    return bool(list_accounts(accounts_path=accounts_path))
