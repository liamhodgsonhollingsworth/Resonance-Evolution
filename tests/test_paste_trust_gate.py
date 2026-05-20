"""
SPEC-073 follow-up: paste trust-gate enforcement (2026-05-20).

Stress-test finding from the post-compact arc named paste-module as
a SPEC-054 bypass: trust gates which .py source files load at
discover() time, but once a type is registered any caller (including
a paste) could spawn it. After this PR, ``instantiate_module`` runs
every snippet's type-name through the engine's render-trust set
BEFORE spawning any node. Failure raises ``UntrustedNodeInPasteError``
and zero nodes are added — atomic rollback.

Test cases cover:

- clean clipboard text (all trusted types) → paste succeeds
- one untrusted node-type → entire paste rejected
- mixed trusted + untrusted → entire paste rejected (all-or-nothing)
- the rejection error names the offending type-names
- regression: re-paste after rejection doesn't leak state
- the trust-set lookup uses ``tools/workflow/trust.py`` (same
  primitive SPEC-054 set up)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from tools.module_clipboard import (  # noqa: E402
    UntrustedNodeInPasteError,
    instantiate_module,
    paste_text_to_engine,
    serialize_module,
)
from tools.workflow.trust import TrustSet, render_trust_set  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _engine_with_trust():
    """Build a real Engine with the workflow scene loaded under the
    production render-trust set. The default trust-set has
    ``node_types/*.py`` and ``renderers/*.py`` patterns admitted —
    so the legitimate snippet types pass and any synthetic
    "outside the pattern" type fails."""
    e = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    return e


def _engine_with_custom_trust(trust_set: TrustSet):
    """Build an engine with the maintainer-supplied trust set so tests
    can revoke trust for individual sources and confirm the paste
    gate rejects them."""
    e = Engine(root_dir=ROOT, trust_set=trust_set)
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    return e


def _make_snippet(type_name: str, node_id: str = "spawned"):
    return json.dumps({
        "module": [
            {"id": node_id, "type": type_name, "params": {}, "connections": {}},
        ]
    })


# ---------------------------------------------------------------------------
# Clean paste — trusted types succeed.
# ---------------------------------------------------------------------------


def test_clean_clipboard_text_with_trusted_only_nodes_succeeds():
    """The default trust-set admits every type in node_types/ and
    renderers/. A round-trip copy + paste of an in-scene panel
    succeeds without rejection."""
    e = _engine_with_trust()
    text = serialize_module(e, "task_panel", include_subtree=True)
    new_ids = paste_text_to_engine(e, text)
    assert "task_panel_2" in new_ids
    assert "task_panel_2" in e.nodes


def test_paste_of_filesource_with_trusted_path_succeeds(tmp_path):
    """A FileSource snippet (typical paste payload) with a path
    inside the project root passes the trust gate because
    FileSource's source-id (``node_types/file_source.py``) matches
    the default-trusted ``node_types/*.py`` pattern."""
    e = _engine_with_trust()
    snippet = json.dumps({
        "module": [
            {
                "id": "fresh_panel",
                "type": "FileSource",
                "params": {"path": "tasks.md", "parser_name": "tasks"},
                "connections": {},
            }
        ]
    })
    new_ids = paste_text_to_engine(e, snippet)
    assert new_ids == ["fresh_panel"]
    assert "fresh_panel" in e.nodes


# ---------------------------------------------------------------------------
# Rejection — single untrusted node type.
# ---------------------------------------------------------------------------


def test_clipboard_with_unknown_type_rejected_entire_paste(tmp_path):
    """A snippet asking to spawn an unknown type-name (no source
    loaded for it) fails the trust gate. Pre-fix this used to spawn
    a dead-but-registered node silently."""
    e = _engine_with_trust()
    before_count = len(e.nodes)
    snippet = _make_snippet("DefinitelyNotARealType")
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, snippet)
    # Nothing added.
    assert len(e.nodes) == before_count
    # The offending type appears in the message + the structured field.
    assert "DefinitelyNotARealType" in str(exc.value)
    assert "DefinitelyNotARealType" in exc.value.offending_types


def test_clipboard_with_untrusted_trusted_set_rejects(tmp_path):
    """Build a trust-set with NO default patterns and only one
    explicit entry. FileSource (whose source is ``node_types/
    file_source.py``) is no longer trusted — the gate rejects."""
    trust_path = tmp_path / "trusted_sources.json"
    ts = TrustSet(path=trust_path, defaults=(), default_patterns=())
    ts.add("never/matches.py")
    # Use a fresh engine without trust to load types first; then swap
    # to the custom trust set so type_sources is populated AND the
    # check sees a no-trust verdict.
    e = Engine(root_dir=ROOT)
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.trust_set = ts

    before_count = len(e.nodes)
    snippet = json.dumps({
        "module": [
            {
                "id": "fresh_panel",
                "type": "FileSource",
                "params": {"path": "tasks.md", "parser_name": "tasks"},
                "connections": {},
            }
        ]
    })
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, snippet)
    assert len(e.nodes) == before_count
    assert "FileSource" in exc.value.offending_types


# ---------------------------------------------------------------------------
# Rejection — mixed trusted + untrusted (all-or-nothing).
# ---------------------------------------------------------------------------


def test_mixed_trusted_and_untrusted_rejects_entire_paste():
    """A snippet with both a trusted type AND an untrusted type is
    rejected — atomic semantics mean even the trusted node is NOT
    spawned. Verified by counting nodes before/after."""
    e = _engine_with_trust()
    before_count = len(e.nodes)
    snippet = json.dumps({
        "module": [
            {
                "id": "trusted_one",
                "type": "FileSource",
                "params": {"path": "tasks.md", "parser_name": "tasks"},
                "connections": {},
            },
            {
                "id": "untrusted_one",
                "type": "ImaginaryType",
                "params": {},
                "connections": {},
            },
        ]
    })
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, snippet)
    # Atomic: neither node spawned.
    assert len(e.nodes) == before_count
    assert "trusted_one" not in e.nodes
    assert "untrusted_one" not in e.nodes
    assert "ImaginaryType" in exc.value.offending_types
    # The trusted type doesn't get listed as offending.
    assert "FileSource" not in exc.value.offending_types


# ---------------------------------------------------------------------------
# Rejection error message details.
# ---------------------------------------------------------------------------


def test_rejection_error_lists_offending_types_in_message():
    """The error message names each offending type so the maintainer
    can decide to grant trust or remove them."""
    e = _engine_with_trust()
    snippet = json.dumps({
        "module": [
            {"id": "a", "type": "TypeAlpha", "params": {}, "connections": {}},
            {"id": "b", "type": "TypeBeta", "params": {}, "connections": {}},
        ]
    })
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, snippet)
    msg = str(exc.value)
    assert "TypeAlpha" in msg
    assert "TypeBeta" in msg
    assert "untrusted node-types" in msg
    # offending_types preserves the input order (deduplicated).
    assert exc.value.offending_types == ["TypeAlpha", "TypeBeta"]


def test_rejection_error_deduplicates_offending_types_in_structured_field():
    """When a snippet contains the same untrusted type multiple
    times, the offending_types list has each name once."""
    e = _engine_with_trust()
    snippet = json.dumps({
        "module": [
            {"id": "a1", "type": "Mystery", "params": {}, "connections": {}},
            {"id": "a2", "type": "Mystery", "params": {}, "connections": {}},
            {"id": "a3", "type": "Mystery", "params": {}, "connections": {}},
        ]
    })
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, snippet)
    assert exc.value.offending_types == ["Mystery"]


# ---------------------------------------------------------------------------
# Regression: re-paste after rejection.
# ---------------------------------------------------------------------------


def test_re_paste_after_rejection_does_not_leak_state():
    """Two consecutive rejections must produce identical node-count
    deltas (i.e. zero on each). The first rejection must not leave
    any partial state that a second paste sees."""
    e = _engine_with_trust()
    snippet = _make_snippet("FakeType")
    initial = dict(e.nodes)
    with pytest.raises(UntrustedNodeInPasteError):
        paste_text_to_engine(e, snippet)
    assert dict(e.nodes) == initial
    with pytest.raises(UntrustedNodeInPasteError):
        paste_text_to_engine(e, snippet)
    assert dict(e.nodes) == initial


def test_rejection_then_clean_paste_still_works():
    """A clean paste AFTER a rejected paste must still succeed. The
    rejection must not leave any cross-call state that breaks
    subsequent legitimate pastes."""
    e = _engine_with_trust()
    bad = _make_snippet("UndefinedType")
    with pytest.raises(UntrustedNodeInPasteError):
        paste_text_to_engine(e, bad)
    # Now a clean paste of a real, trusted in-scene panel.
    text = serialize_module(e, "wish_panel", include_subtree=True)
    new_ids = paste_text_to_engine(e, text)
    assert "wish_panel_2" in new_ids
    assert "wish_panel_2" in e.nodes


# ---------------------------------------------------------------------------
# The trust-set lookup uses the same primitive SPEC-054 set up.
# ---------------------------------------------------------------------------


def test_trust_set_primitive_is_workflow_trust_module(tmp_path):
    """The gate consults the engine's ``trust_set`` attribute, which
    is the ``TrustSet`` from ``tools/workflow/trust.py``. This test
    proves the gate sees changes the maintainer makes through the
    SPEC-054 trust-store: add a custom source, verify it's
    recognised as trusted; remove it, verify rejection."""
    # Build a trust-set whose ONLY trusted entry is a custom path.
    trust_path = tmp_path / "trusted_sources.json"
    ts = TrustSet(path=trust_path, defaults=(), default_patterns=())
    # Use the actual source-id of FileSource.
    ts.add("node_types/file_source.py")

    e = Engine(root_dir=ROOT)
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.trust_set = ts

    # FileSource is trusted by explicit add.
    snippet = json.dumps({
        "module": [
            {
                "id": "fresh_via_explicit_trust",
                "type": "FileSource",
                "params": {"path": "tasks.md", "parser_name": "tasks"},
                "connections": {},
            }
        ]
    })
    new_ids = paste_text_to_engine(e, snippet)
    assert "fresh_via_explicit_trust" in new_ids

    # ListRenderer was NEVER added to trust → its source-id
    # (renderers/list_renderer.py) fails the check.
    list_snippet = json.dumps({
        "module": [
            {
                "id": "fresh_renderer",
                "type": "ListRenderer",
                "params": {},
                "connections": {},
            }
        ]
    })
    with pytest.raises(UntrustedNodeInPasteError) as exc:
        paste_text_to_engine(e, list_snippet)
    assert "ListRenderer" in exc.value.offending_types


# ---------------------------------------------------------------------------
# No-trust-set path — backward compatibility preserved.
# ---------------------------------------------------------------------------


def test_engine_without_trust_set_skips_the_gate():
    """When the engine has no trust_set (tests + pre-trust callers),
    instantiate_module's check is a no-op. Existing tests built on
    untrusted engines keep working."""
    e = Engine(root_dir=ROOT)
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    assert e.trust_set is None
    snippet = json.dumps({
        "module": [
            {
                "id": "no_trust_paste",
                "type": "FileSource",
                "params": {"path": "tasks.md", "parser_name": "tasks"},
                "connections": {},
            }
        ]
    })
    new_ids = paste_text_to_engine(e, snippet)
    assert "no_trust_paste" in new_ids


def test_instantiate_module_with_enforce_trust_false_bypasses_gate():
    """Trusted internal callers (e.g. scene restoration) can pass
    enforce_trust=False to skip the gate. This is the opt-out path
    for cases where the snippet was constructed by the engine
    itself, not by a paste from outside."""
    e = _engine_with_trust()
    before_count = len(e.nodes)
    module = [
        {"id": "bypass_node", "type": "FileSource",
         "params": {"path": "tasks.md", "parser_name": "tasks"},
         "connections": {}},
    ]
    # With enforce_trust=False, gate is skipped even though FileSource
    # is trusted (this just exercises the opt-out path; the legitimate
    # case is when the type would otherwise fail).
    new_ids = instantiate_module(e, module, enforce_trust=False)
    assert "bypass_node" in new_ids
    assert len(e.nodes) == before_count + 1
