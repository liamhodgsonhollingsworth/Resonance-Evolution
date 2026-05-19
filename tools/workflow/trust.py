"""
Trust-set primitive — the foundation for SPEC-053 trust-based gating.

Three distinct trust-sets compose against this primitive:

- ``render_trust_set(root)`` — source paths whose node-types may be
  materialized by the engine. Default-trusted: any path matching
  ``node_types/*.py`` or ``renderers/*.py`` (the local repo's curated
  directories). Composes SPEC-054.
- ``sender_trust_set(root, user)`` — sender identities whose inbox
  messages reach the main inbox. Untrusted senders route to quarantine
  (SPEC-058). Composes SPEC-057.
- ``session_trust_set(root, user)`` — sender identities whose messages
  are delivered to running Claude Code sessions. Initial default: the
  maintainer (``user``) only. Composes SPEC-059.

Each ``TrustSet`` persists to a JSON file under ``state/`` (gitignored
by the existing ``state/`` rule in ``.gitignore``). Identities are
arbitrary strings; default-trust patterns apply only to render-trust.
"""

from __future__ import annotations

import fnmatch
import json
import os
import threading
import time
from pathlib import Path
from typing import Iterable, List, Optional, Set


DEFAULT_TRUSTED_SOURCES_PATH = Path("state/trusted_sources.json")
DEFAULT_TRUSTED_SENDERS_PATH = Path("state/trusted_senders.json")
DEFAULT_SESSION_TRUSTED_SENDERS_PATH = Path("state/session_trusted_senders.json")

DEFAULT_TRUSTED_RENDER_PATTERNS = (
    "node_types/*.py",
    "renderers/*.py",
)


class TrustError(Exception):
    """Raised when trust-store load/save fails in a way the caller should
    know about (unsupported version, etc.). Untrusted identities are NOT
    errors — they are the normal trust-check path.
    """


class TrustSet:
    """A persistent set of trusted identities.

    Identities are strings. The semantics of an identity depend on the
    caller: a source-path for render-trust, a sender-string for inbox-
    trust, or a session-trust value. ``TrustSet`` itself is identity-
    agnostic — it answers ``is_trusted(identity)``.

    Persistence is JSON with the shape::

        {"version": 1, "trusted": ["identity1", "identity2", ...]}

    The file is written via tmp + ``os.replace`` with retry-on-PermissionError
    (Windows can raise on rename-over-open-file).
    """

    def __init__(
        self,
        path: Path,
        *,
        defaults: Iterable[str] = (),
        default_patterns: Iterable[str] = (),
    ):
        self.path = Path(path)
        self.default_patterns = tuple(default_patterns)
        self._lock = threading.Lock()
        self._cache_set: Optional[Set[str]] = None
        self._cache_key: tuple = (-1.0, -1)  # (mtime, size)
        if not self.path.exists():
            self._init_with_defaults(defaults)

    def is_trusted(self, identity: str) -> bool:
        if not identity:
            return False
        with self._lock:
            trusted = self._load_set()
        if identity in trusted:
            return True
        for pattern in self.default_patterns:
            if _segment_match(identity, pattern):
                return True
        return False

    def add(self, identity: str) -> None:
        if not identity:
            raise TrustError("Cannot trust an empty identity.")
        if not isinstance(identity, str):
            raise TrustError("Identity must be a string.")
        with self._lock:
            trusted = self._load_set()
            trusted.add(identity)
            self._save_set(trusted)

    def remove(self, identity: str) -> None:
        with self._lock:
            trusted = self._load_set()
            trusted.discard(identity)
            self._save_set(trusted)

    def list_trusted(self) -> List[str]:
        with self._lock:
            return sorted(self._load_set())

    def _init_with_defaults(self, defaults: Iterable[str]) -> None:
        defaults_set = {d for d in defaults if isinstance(d, str) and d}
        try:
            self._save_set(defaults_set)
        except OSError:
            pass

    def _load_set(self) -> Set[str]:
        if not self.path.exists():
            self._cache_set = set()
            self._cache_key = (-1.0, -1)
            return set()
        try:
            st = self.path.stat()
            key = (st.st_mtime, st.st_size)
        except OSError:
            return set()
        if self._cache_set is not None and key == self._cache_key:
            return self._cache_set
        try:
            with self.path.open("r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            self._cache_set = set()
            self._cache_key = key
            return set()
        if not isinstance(data, dict):
            self._cache_set = set()
            self._cache_key = key
            return set()
        version = data.get("version")
        if version != 1:
            raise TrustError(f"Unsupported trust-set version: {version!r}")
        trusted = data.get("trusted", [])
        if not isinstance(trusted, list):
            self._cache_set = set()
            self._cache_key = key
            return set()
        result = {s for s in trusted if isinstance(s, str) and s}
        self._cache_set = result
        self._cache_key = key
        return result

    def _save_set(self, trusted: Set[str]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {"version": 1, "trusted": sorted(trusted)}
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        last_exc: Optional[Exception] = None
        for attempt in range(10):
            try:
                os.replace(tmp, self.path)
                self._cache_set = set(trusted)
                try:
                    st = self.path.stat()
                    self._cache_key = (st.st_mtime, st.st_size)
                except OSError:
                    self._cache_set = None
                    self._cache_key = (-1.0, -1)
                return
            except PermissionError as exc:
                last_exc = exc
                time.sleep(0.005 * (attempt + 1))
        raise last_exc if last_exc else OSError("os.replace failed")


def _segment_match(identity: str, pattern: str) -> bool:
    """Segment-aware fnmatch.

    Splits both identity and pattern on ``/`` and matches segment-by-
    segment. A ``*`` glob does NOT cross ``/`` boundaries, and segment
    counts must match exactly. So ``node_types/*.py`` matches
    ``node_types/cube.py`` but not ``node_types/parsers/ideas.py`` or
    ``external/node_types/cube.py``.
    """
    id_parts = identity.split("/")
    pat_parts = pattern.split("/")
    if len(id_parts) != len(pat_parts):
        return False
    return all(fnmatch.fnmatchcase(i, p) for i, p in zip(id_parts, pat_parts))


def render_trust_set(root: Path) -> TrustSet:
    """Render-trust: node-type source paths the engine may materialize.

    Default patterns cover the local repo's curated directories
    (``node_types/*.py``, ``renderers/*.py``). The maintainer can add
    explicit entries to trust sources outside those patterns.
    """
    path = Path(root) / DEFAULT_TRUSTED_SOURCES_PATH
    return TrustSet(
        path=path,
        defaults=(),
        default_patterns=DEFAULT_TRUSTED_RENDER_PATTERNS,
    )


def sender_trust_set(root: Path, user: Optional[str] = None) -> TrustSet:
    """Sender-trust for the maintainer's inbox.

    Default-trusted: ``workflow-shell`` (the shell's own outgoing
    messages) plus the maintainer's username when known. Workers /
    sessions become trusted via explicit ``add()`` when the maintainer
    promotes them from quarantine.
    """
    path = Path(root) / DEFAULT_TRUSTED_SENDERS_PATH
    defaults = ["workflow-shell"]
    if user:
        defaults.append(user)
    return TrustSet(path=path, defaults=defaults)


def session_trust_set(root: Path, user: Optional[str] = None) -> TrustSet:
    """Session-trust for messages addressed to running sessions.

    Initial default: the maintainer (``user``) only. Other senders go
    to quarantine for maintainer review. Composes with SPEC-057's
    maintainer-side trust: a sender can be trusted for the maintainer's
    inbox but NOT for sessions, or vice versa.
    """
    path = Path(root) / DEFAULT_SESSION_TRUSTED_SENDERS_PATH
    defaults = []
    if user:
        defaults.append(user)
    return TrustSet(path=path, defaults=defaults)
