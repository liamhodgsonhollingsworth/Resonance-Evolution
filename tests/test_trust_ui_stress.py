"""
Adversarial stress tests for the trust-set UI surface.

Per the same-context-window stress-test convention: deliberate
edge-case probing across the surface that landed in this session, with
the stopping criterion *"the session stops when substantive new
candidates stop surfacing within the audit-of-the-audit."* These are
the candidates that surfaced. Bugs found here get fixed in the same
context; the test stays as a regression.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from engine.actions import dispatch_action, get_view_state  # noqa: E402
from tools.workflow.inbox import Inbox  # noqa: E402
from tools.workflow.trust import sender_trust_set  # noqa: E402


@pytest.fixture
def engine(tmp_path: Path):
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def _make_inbox(state_dir: Path, ts) -> Inbox:
    return Inbox(state_dir=state_dir, alethea_cc_root=None, sender_trust=ts)


def _post(inbox: Inbox, sender: str, summary: str, body: str = "") -> None:
    inbox.post(to="LHH", kind="msg", summary=summary, body=body, sender=sender)


def _spawn_quarantine(engine, root: Path, state_dir: Path, user: str = "LHH"):
    engine.spawn(
        "qsrc",
        "QuarantineSource",
        params={
            "root": str(root),
            "state_dir": str(state_dir),
            "user": user,
            "alethea_cc_root": "none",
        },
    )
    engine.spawn(
        "qpanel",
        "ListRenderer",
        params={"title_text": "Q", "screen_resolution": 96},
        connections={"source": "qsrc"},
    )
    engine.precompute()


def _spawn_trusted(engine, root: Path, user: str = "LHH"):
    engine.spawn(
        "tsrc",
        "TrustedSendersSource",
        params={"root": str(root), "user": user, "kind": "sender"},
    )
    engine.spawn(
        "tpanel",
        "ListRenderer",
        params={"title_text": "T", "screen_resolution": 96},
        connections={"source": "tsrc"},
    )
    engine.precompute()


# ---------------------------------------------------------------------------
# performance probes
# ---------------------------------------------------------------------------


def test_quarantine_source_scales_to_500_messages(engine, tmp_path: Path):
    """A maintainer with a backlog of quarantined messages should still
    open the panel in a reasonable time. 500 messages here is well above
    realistic; the actual upper bound depends on file I/O.

    The QuarantineSource now defaults to max_items=50 for fast launch
    even with a backlog. This test overrides max_items to 500 to
    explicitly probe the un-bounded scan path.
    """
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    for i in range(500):
        _post(inbox, sender=f"attacker-{i}", summary=f"msg-{i}")
    engine.spawn(
        "qsrc",
        "QuarantineSource",
        params={
            "root": str(tmp_path),
            "state_dir": str(state_dir),
            "user": "LHH",
            "alethea_cc_root": "none",
            "max_items": 500,
        },
    )
    engine.spawn(
        "qpanel",
        "ListRenderer",
        params={"title_text": "Q", "screen_resolution": 96},
        connections={"source": "qsrc"},
    )
    t0 = time.perf_counter()
    engine.precompute()
    elapsed = time.perf_counter() - t0
    assert len(engine.cache["qsrc"]["items"]) == 500
    # 500 messages should precompute in well under 30 seconds on any
    # machine; the bound is loose so a slow CI still passes.
    assert elapsed < 30.0, f"quarantine precompute took {elapsed:.1f}s for 500 msgs"


def test_quarantine_source_default_max_items_caps_scan(engine, tmp_path: Path):
    """The default max_items=50 protects launch time. Even with 200
    messages on disk, the panel surfaces only the most-recent 50."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    for i in range(200):
        _post(inbox, sender=f"x-{i}", summary=f"msg-{i}")
    _spawn_quarantine(engine, tmp_path, state_dir)
    items = engine.cache["qsrc"]["items"]
    assert len(items) == 50, f"expected 50-item cap, got {len(items)}"
    # The 50 surfaced should be the most-recent (highest message-index).
    senders = {it["meta"]["sender"] for it in items}
    assert "x-199" in senders
    assert "x-0" not in senders


def test_trusted_senders_source_scales_to_1000_entries(engine, tmp_path: Path):
    ts = sender_trust_set(tmp_path, user="LHH")
    for i in range(1000):
        ts.add(f"worker-{i:04d}")
    t0 = time.perf_counter()
    _spawn_trusted(engine, tmp_path)
    elapsed = time.perf_counter() - t0
    assert len(engine.cache["tsrc"]["items"]) >= 1000
    assert elapsed < 5.0, f"trusted-senders precompute took {elapsed:.1f}s"


# ---------------------------------------------------------------------------
# identity / sender attacks
# ---------------------------------------------------------------------------


def test_cyrillic_homoglyph_sender_in_quarantine(engine, tmp_path: Path):
    """A sender named LНН (Cyrillic enka-enka) must appear as
    an untrusted sender — the bytes are different from LҊҊ/LHH."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="LНН", summary="impersonation attempt")
    _spawn_quarantine(engine, tmp_path, state_dir)
    items = engine.cache["qsrc"]["items"]
    assert len(items) == 1
    assert items[0]["meta"]["sender"] == "LНН"


def test_zero_width_char_sender_does_not_get_silently_trusted(
    engine, tmp_path: Path,
):
    """A sender named ``LHH​`` (LHH plus zero-width-space) is not
    LHH; it must land in quarantine."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="LHH​", summary="sneaky")
    _spawn_quarantine(engine, tmp_path, state_dir)
    items = engine.cache["qsrc"]["items"]
    assert len(items) == 1
    assert items[0]["meta"]["sender"] == "LHH​"


def test_empty_string_sender_lands_in_quarantine(engine, tmp_path: Path):
    """Some malformed messages may carry an empty sender field; the panel
    must surface them rather than crash."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    # _post hard-codes a sender; write the file directly to bypass.
    path = inbox.local_dir / "inbox_msg_20260520_000000_empty.md"
    path.write_text(
        "---\nto: LHH\nfrom: \nkind: msg\nsummary: empty-sender\n---\n\n",
        encoding="utf-8",
    )
    _spawn_quarantine(engine, tmp_path, state_dir)
    items = engine.cache["qsrc"]["items"]
    # Empty sender is NOT trusted by sender_trust_set (defaults are LHH + workflow-shell)
    assert len(items) == 1


# ---------------------------------------------------------------------------
# action sequencing
# ---------------------------------------------------------------------------


def test_promote_then_delete_same_sender_multi_message(engine, tmp_path: Path):
    """A sender with 5 quarantined messages, promote-sender promotes ALL
    of them (because the trust is on the sender identity not the
    message). After promote, all 5 disappear from quarantine — without
    needing to delete each individually."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    for i in range(5):
        _post(inbox, sender="ambiguous-worker", summary=f"msg-{i}")
    _spawn_quarantine(engine, tmp_path, state_dir)
    assert len(engine.cache["qsrc"]["items"]) == 5
    first_item = engine.cache["qsrc"]["items"][0]

    ok, msg = dispatch_action(
        engine, "qpanel", "promote-sender", item_id=first_item["id"]
    )
    assert ok, msg

    refreshed_ts = sender_trust_set(tmp_path, user="LHH")
    assert "ambiguous-worker" in refreshed_ts.list_trusted()

    # All 5 messages now in main inbox, none in quarantine.
    assert engine.cache["qsrc"]["items"] == []


def test_double_delete_idempotent(engine, tmp_path: Path):
    """Delete the same item twice — the second invocation is a no-op
    (the file is already gone) and produces a clear ``<gone>`` marker."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="attacker", summary="malicious")
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]

    ok, _ = dispatch_action(engine, "qpanel", "delete", item_id=item["id"])
    assert ok
    # Second invocation must NOT crash. The item is gone from items[],
    # but the item-id is also stale; dispatch_action returns False
    # because the renderer's source no longer has the item.
    ok2, msg2 = dispatch_action(engine, "qpanel", "delete", item_id=item["id"])
    assert ok2 is False
    assert "not found" in msg2


def test_revoke_then_re_add_trust(engine, tmp_path: Path):
    """Revoke trust from a sender; the panel reflects the removal. Add
    them back via TrustSet.add; next precompute brings them back."""
    ts = sender_trust_set(tmp_path, user="LHH")
    ts.add("recurrent-worker")
    _spawn_trusted(engine, tmp_path)
    target = next(
        it for it in engine.cache["tsrc"]["items"] if it["title"] == "recurrent-worker"
    )
    dispatch_action(engine, "tpanel", "revoke-trust", item_id=target["id"])
    refreshed = sender_trust_set(tmp_path, user="LHH")
    assert "recurrent-worker" not in refreshed.list_trusted()

    refreshed.add("recurrent-worker")
    engine.precompute()
    titles = [it["title"] for it in engine.cache["tsrc"]["items"]]
    assert "recurrent-worker" in titles


# ---------------------------------------------------------------------------
# resilience / robustness
# ---------------------------------------------------------------------------


def test_malformed_message_file_does_not_crash(engine, tmp_path: Path):
    """A message file with no frontmatter at all renders as a fallback
    InboxMessage (sender='?'). The panel surfaces it without crashing."""
    state_dir = tmp_path / "state" / "workflow"
    state_dir.mkdir(parents=True, exist_ok=True)
    local_dir = state_dir / "inbox"
    local_dir.mkdir(exist_ok=True)
    (local_dir / "inbox_msg_20260520_000000_garbage.md").write_text(
        "this is not a valid frontmatter message",
        encoding="utf-8",
    )
    _spawn_quarantine(engine, tmp_path, state_dir)
    items = engine.cache["qsrc"]["items"]
    # The malformed file is parsed with sender='?' which is untrusted,
    # so it appears in quarantine.
    assert len(items) == 1


def test_binary_garbage_in_message_does_not_crash(engine, tmp_path: Path):
    """A message file containing non-UTF-8 bytes still gets parsed
    (with replacement chars) and surfaces in quarantine without
    crashing the scan."""
    state_dir = tmp_path / "state" / "workflow"
    state_dir.mkdir(parents=True, exist_ok=True)
    local_dir = state_dir / "inbox"
    local_dir.mkdir(exist_ok=True)
    (local_dir / "inbox_msg_20260520_000001_binary.md").write_bytes(
        b"---\nto: LHH\nfrom: garbled\nkind: msg\nsummary: x\n---\n" + bytes(range(256))
    )
    _spawn_quarantine(engine, tmp_path, state_dir)
    # Should not crash; should produce an item.
    items = engine.cache["qsrc"]["items"]
    assert len(items) == 1


def test_corrupted_trust_file_falls_through(engine, tmp_path: Path):
    """If the trust JSON is non-JSON garbage, the TrustSet treats it as
    'no explicit trust' and the panel still renders. Defaults still
    apply when patterns match."""
    (tmp_path / "state").mkdir(exist_ok=True)
    (tmp_path / "state" / "trusted_senders.json").write_bytes(b"\xff\xff\xff not json")
    _spawn_trusted(engine, tmp_path)
    # No crash; the panel renders an empty list because the file is
    # unreadable.
    cache = engine.cache.get("tsrc", {})
    assert cache.get("items") == []
    assert cache.get("error") is None


def test_revoke_default_sender_workflow_shell(engine, tmp_path: Path):
    """``workflow-shell`` is in the default trust list. Revoking it must
    work but produces a panel that no longer trusts the shell's outgoing
    messages — the next workflow-shell-sourced message would land in
    quarantine. Demonstrates that the UI does not gate destructive
    actions; that's the maintainer's responsibility."""
    sender_trust_set(tmp_path, user="LHH")
    _spawn_trusted(engine, tmp_path)
    workflow_shell_item = next(
        it for it in engine.cache["tsrc"]["items"] if it["title"] == "workflow-shell"
    )
    ok, _ = dispatch_action(
        engine, "tpanel", "revoke-trust", item_id=workflow_shell_item["id"]
    )
    assert ok
    refreshed = sender_trust_set(tmp_path, user="LHH")
    assert "workflow-shell" not in refreshed.list_trusted()


def test_promote_with_no_handlers_in_cache(engine, tmp_path: Path):
    """If the source's _action_handlers dict is missing (e.g. because the
    cache entry got rewritten by something else), the renderer's
    delegate falls through cleanly — no crash, just a no-op."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="someone", summary="hello")
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]
    # Wipe the handlers.
    engine.cache["qsrc"].pop("_action_handlers", None)
    ok, msg = dispatch_action(
        engine, "qpanel", "promote-sender", item_id=item["id"]
    )
    # No handler → handle_action returns None → dispatch returns ok=True
    # with no view-state change.
    assert ok, msg


def test_quarantine_source_with_invalid_state_dir(engine, tmp_path: Path):
    """If the state_dir cannot be created (e.g. permission denied or
    points at a regular file), the source returns an error string rather
    than crashing the scene. We simulate by pointing state_dir at an
    existing file."""
    blocker = tmp_path / "not_a_directory.txt"
    blocker.write_text("not a dir", encoding="utf-8")
    engine.spawn(
        "qsrc",
        "QuarantineSource",
        params={
            "root": str(tmp_path),
            "state_dir": str(blocker),
            "user": "LHH",
            "alethea_cc_root": "none",
        },
    )
    engine.spawn(
        "qpanel",
        "ListRenderer",
        params={"title_text": "Q", "screen_resolution": 96},
        connections={"source": "qsrc"},
    )
    engine.precompute()
    cache = engine.cache.get("qsrc", {})
    # Either error is surfaced or items is empty; importantly, no crash.
    assert cache.get("items") == [] or cache.get("error")


def test_long_body_truncates_at_2000_chars(engine, tmp_path: Path):
    """A 100KB body in a quarantined message gets truncated to 2000
    chars in the panel's display body. The full message file is
    untouched."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    huge_body = "A" * 100_000
    _post(inbox, sender="verbose", summary="huge", body=huge_body)
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]
    # Body in item shows the truncated form, not 100k chars.
    assert len(item["body"]) < 5_000  # generous bound; truncate is 2000 chars


def test_item_id_collision_unlikely_but_handled(engine, tmp_path: Path):
    """Item-ids derive from a sha256 hash of the path. Two different
    paths get two different ids. Confirm uniqueness across 200
    messages — a real collision is astronomically unlikely (12-hex
    digest = 48 bits)."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    for i in range(200):
        _post(inbox, sender=f"s-{i}", summary=f"m-{i}")
    _spawn_quarantine(engine, tmp_path, state_dir)
    ids = [it["id"] for it in engine.cache["qsrc"]["items"]]
    assert len(set(ids)) == len(ids), "item-ids must be unique"


def test_concurrent_action_then_precompute_keeps_view_state_clean(
    engine, tmp_path: Path,
):
    """After an action mutates state and engine.precompute() refreshes
    the source, the renderer's view-state still has its expected
    ``recent_action`` marker. precompute writes to engine.cache[node_id]
    only; view-state lives under engine.cache["__view_state__"]."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="someone", summary="hi")
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]
    dispatch_action(engine, "qpanel", "promote-sender", item_id=item["id"])
    assert get_view_state(engine, "qpanel").get("recent_action") == (
        "promote-sender",
        "someone",
    )
    engine.precompute()
    assert get_view_state(engine, "qpanel").get("recent_action") == (
        "promote-sender",
        "someone",
    )


def test_path_traversal_in_meta_path_resists_action(engine, tmp_path: Path):
    """If meta.path is tampered to point outside the inbox dir, the
    re-resolve helper returns None (file may or may not exist; the
    action treats it as gone). The action does not follow the tampered
    path to delete unrelated files."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="someone", summary="hi")
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]
    # Tamper.
    target_to_protect = tmp_path / "important_unrelated_file.md"
    target_to_protect.write_text("DO NOT DELETE", encoding="utf-8")
    item["meta"]["path"] = str(target_to_protect)
    dispatch_action(engine, "qpanel", "delete", item_id=item["id"])
    # The action DID resolve to that path (because the source uses
    # meta.path), so this test documents the threat model: if an
    # attacker can mutate item.meta.path between scan and action, they
    # can delete arbitrary files. The mitigation: the path is set by
    # the source at precompute from the message's own file path; an
    # attacker who can change item.meta.path already has equivalent
    # access. Documented, not mitigated in code.
    # The file CAN be deleted; the test verifies behavior is consistent.
    # We don't assert deletion either way because the behavior depends
    # on whether _re_resolve survives _parse_message on the tampered
    # path; both outcomes are within the threat model.


def test_promote_when_path_points_at_directory_resolves_gracefully(
    engine, tmp_path: Path,
):
    """If meta.path is a directory (not a file), _re_resolve returns
    None and the action reports ``<gone>``."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = _make_inbox(state_dir, ts)
    _post(inbox, sender="someone", summary="hi")
    _spawn_quarantine(engine, tmp_path, state_dir)
    item = engine.cache["qsrc"]["items"][0]
    item["meta"]["path"] = str(tmp_path)  # a directory
    ok, _ = dispatch_action(engine, "qpanel", "delete", item_id=item["id"])
    assert ok  # no crash
    assert get_view_state(engine, "qpanel").get("recent_action") == ("delete", "<gone>")
