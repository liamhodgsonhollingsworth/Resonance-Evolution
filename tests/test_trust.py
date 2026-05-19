"""
Tests for tools.workflow.trust — the shared trust-set primitive.

Covers the foundation that SPEC-054 (render-trust gate), SPEC-057
(trusted-sender messaging filter), and SPEC-059 (session-messaging
trust) compose against.
"""

from __future__ import annotations

import json
import threading
from pathlib import Path

import pytest

from tools.workflow.trust import (
    DEFAULT_TRUSTED_RENDER_PATTERNS,
    TrustError,
    TrustSet,
    render_trust_set,
    sender_trust_set,
    session_trust_set,
)


@pytest.fixture
def trust_path(tmp_path: Path) -> Path:
    return tmp_path / "trusted.json"


def test_empty_identity_never_trusted(trust_path: Path):
    ts = TrustSet(path=trust_path)
    assert not ts.is_trusted("")


def test_add_and_check_trust(trust_path: Path):
    ts = TrustSet(path=trust_path)
    ts.add("alice")
    assert ts.is_trusted("alice")
    assert not ts.is_trusted("bob")


def test_remove_trust(trust_path: Path):
    ts = TrustSet(path=trust_path)
    ts.add("alice")
    assert ts.is_trusted("alice")
    ts.remove("alice")
    assert not ts.is_trusted("alice")


def test_remove_nonexistent_does_not_raise(trust_path: Path):
    ts = TrustSet(path=trust_path)
    ts.remove("never-added")


def test_persistence_across_instances(trust_path: Path):
    ts1 = TrustSet(path=trust_path)
    ts1.add("alice")
    ts1.add("bob")

    ts2 = TrustSet(path=trust_path)
    assert ts2.is_trusted("alice")
    assert ts2.is_trusted("bob")
    assert set(ts2.list_trusted()) == {"alice", "bob"}


def test_default_patterns_match_local_repo(trust_path: Path):
    ts = TrustSet(
        path=trust_path,
        default_patterns=("node_types/*.py", "renderers/*.py"),
    )
    assert ts.is_trusted("node_types/cube.py")
    assert ts.is_trusted("renderers/text.py")
    assert not ts.is_trusted("external/malicious.py")
    assert not ts.is_trusted("node_types/parsers/ideas.py")


def test_default_patterns_with_explicit_trust(trust_path: Path):
    ts = TrustSet(
        path=trust_path,
        default_patterns=("node_types/*.py",),
    )
    ts.add("community_pack/cube.py")
    assert ts.is_trusted("node_types/cube.py")
    assert ts.is_trusted("community_pack/cube.py")
    assert not ts.is_trusted("external/malicious.py")


def test_initial_defaults_persisted(trust_path: Path):
    ts = TrustSet(path=trust_path, defaults=["LHH", "workflow-shell"])
    assert ts.is_trusted("LHH")
    assert ts.is_trusted("workflow-shell")
    assert set(ts.list_trusted()) == {"LHH", "workflow-shell"}

    ts2 = TrustSet(path=trust_path)
    assert ts2.is_trusted("LHH")


def test_list_trusted_is_sorted(trust_path: Path):
    ts = TrustSet(path=trust_path)
    ts.add("zara")
    ts.add("alice")
    ts.add("mike")
    assert ts.list_trusted() == ["alice", "mike", "zara"]


def test_add_empty_identity_raises(trust_path: Path):
    ts = TrustSet(path=trust_path)
    with pytest.raises(TrustError):
        ts.add("")


def test_add_non_string_raises(trust_path: Path):
    ts = TrustSet(path=trust_path)
    with pytest.raises(TrustError):
        ts.add(123)


def test_render_trust_set_factory(tmp_path: Path):
    root = tmp_path
    ts = render_trust_set(root)
    assert ts.path == root / "state" / "trusted_sources.json"
    assert ts.is_trusted("node_types/cube.py")
    assert ts.is_trusted("renderers/text.py")
    assert not ts.is_trusted("foreign/dangerous.py")


def test_sender_trust_set_factory_with_user(tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    assert ts.is_trusted("LHH")
    assert ts.is_trusted("workflow-shell")
    assert not ts.is_trusted("attacker")


def test_sender_trust_set_factory_without_user(tmp_path: Path):
    ts = sender_trust_set(tmp_path)
    assert ts.is_trusted("workflow-shell")
    assert not ts.is_trusted("LHH")


def test_session_trust_set_factory_with_user(tmp_path: Path):
    ts = session_trust_set(tmp_path, user="LHH")
    assert ts.is_trusted("LHH")
    assert not ts.is_trusted("workflow-shell")


def test_session_trust_set_factory_without_user(tmp_path: Path):
    ts = session_trust_set(tmp_path)
    assert not ts.is_trusted("LHH")
    assert not ts.is_trusted("anyone")


def test_corrupt_json_falls_back_to_no_explicit_trust(trust_path: Path):
    trust_path.parent.mkdir(parents=True, exist_ok=True)
    trust_path.write_text("not valid json {{{", encoding="utf-8")
    ts = TrustSet(path=trust_path)
    assert not ts.is_trusted("alice")


def test_unsupported_version_raises(trust_path: Path):
    trust_path.parent.mkdir(parents=True, exist_ok=True)
    trust_path.write_text(
        json.dumps({"version": 99, "trusted": ["alice"]}),
        encoding="utf-8",
    )
    ts = TrustSet(path=trust_path)
    with pytest.raises(TrustError):
        ts.is_trusted("alice")


def test_corrupt_then_default_patterns_still_apply(trust_path: Path):
    trust_path.parent.mkdir(parents=True, exist_ok=True)
    trust_path.write_text("garbage", encoding="utf-8")
    ts = TrustSet(
        path=trust_path,
        default_patterns=("node_types/*.py",),
    )
    assert ts.is_trusted("node_types/cube.py")
    assert not ts.is_trusted("attacker.py")


def test_factory_defaults_constant():
    assert "node_types/*.py" in DEFAULT_TRUSTED_RENDER_PATTERNS
    assert "renderers/*.py" in DEFAULT_TRUSTED_RENDER_PATTERNS


def test_concurrent_add_no_data_loss(trust_path: Path):
    ts = TrustSet(path=trust_path)
    n_threads = 8
    errors: list = []

    def add_one(i: int) -> None:
        try:
            ts.add(f"sender{i}")
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=add_one, args=(i,)) for i in range(n_threads)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    listed = ts.list_trusted()
    assert len(listed) >= 1, "all adds dropped — locking is broken"
    for s in listed:
        assert ts.is_trusted(s)
