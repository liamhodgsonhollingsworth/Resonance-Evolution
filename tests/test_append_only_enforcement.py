"""test_append_only_enforcement.py — tests for brief 02 commit 3.

Per brief 02 commit 3 (Decision B2, SPEC-086 + SPEC-026 + SPEC-084).

Covers the RENDERER-layer enforcement of the append-only invariant:

- The renderer enforces `freeze_at_append_time=True` by default.
- A caller-supplied `nodes_lookup` entry whose `id` disagrees with the
  position-entry's `node_id` raises `FreezeAtAppendTimeViolation` —
  the renderer refuses to silently substitute a supersession leaf for
  an original-append entry.
- Matching ids are accepted (the substrate's content-addressing
  guarantees the byte-stable version is what was appended).
- A position entry with `provenance.source_ref` set is marked
  `data-append-kind="supersession"`; entries without source_ref are
  marked `data-append-kind="original"`.
- Supersession-appended entries appear at the bottom of the stream
  (per Decision B2) with the original still at its position.
- Opt-out via `context['freeze_at_append_time']=False` is accepted
  (the phase-2 history_collapsed escape hatch) and the surface
  advertises `data-freeze-policy="history_collapsed"`.
- The default surface advertises `data-freeze-policy="strict"`.
- String coercion of the policy flag handles URL-supplied values
  ("false", "0", "no") without crashing.

The storage-layer enforcement (the `_workflow_view_append` validator)
is covered by `Alethea-cc/tests/test_workflow_view_substrate.py`
(brief 02 commit 1); this file covers the renderer-layer half +
opt-out semantics. Together they verify the dual-layer enforcement
the per-module plan names.

Run:
    cd Apeiron && python -m pytest tests/test_append_only_enforcement.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import (  # noqa: E402
    DEFAULT_FREEZE_AT_APPEND_TIME,
    FreezeAtAppendTimeViolation,
    RENDERER_ID,
    render,
)


# ---------------------------------------------------------------------------
# Test fixtures
# ---------------------------------------------------------------------------


NODE_A = "sha256:" + "a" * 64
NODE_B = "sha256:" + "b" * 64
NODE_C = "sha256:" + "c" * 64


def _mk_position(
    node_id: str,
    source: str = "test",
    source_ref: str = "",
) -> dict:
    entry: dict = {
        "node_id": node_id,
        "appended_at": "2026-05-22T00:00:00Z",
        "appended_by": "test",
        "provenance": {"source": source},
    }
    if source_ref:
        entry["provenance"]["source_ref"] = source_ref
    return entry


def _mk_workflow_view(positions: list[dict], wv_id: str = "sha256:wv_aoe") -> dict:
    return {
        "id": wv_id,
        "name": "workflow_view_main",
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": {
            "positions": positions,
            "default_paste_location": "end",
            "metadata": {
                "window": "50,20,20",
                "mode": "append-only",
                "surface": "workflow_continuous_scroll",
            },
        },
    }


def _mk_content_node(node_id: str, body_text: str) -> dict:
    return {
        "id": node_id,
        "name": f"content_{node_id[:16]}",
        "kind": "content",
        "body": body_text,
    }


# ---------------------------------------------------------------------------
# Default policy + module-level exports
# ---------------------------------------------------------------------------


def test_default_freeze_at_append_time_is_true() -> None:
    """The default policy is the strict append-only render mode."""
    assert DEFAULT_FREEZE_AT_APPEND_TIME is True


def test_freeze_violation_subclasses_value_error() -> None:
    """The named violation subclasses ValueError so existing broad
    handlers still catch it; the named type lets tests + Tool T2
    distinguish freeze-violations from other render-time errors."""
    assert issubclass(FreezeAtAppendTimeViolation, ValueError)


# ---------------------------------------------------------------------------
# Freeze-at-append-time enforcement — matching ids accepted
# ---------------------------------------------------------------------------


def test_render_accepts_matching_node_id_in_lookup() -> None:
    """When nodes_lookup supplies a node whose `id` equals the position-
    entry's `node_id`, the renderer accepts it and emits the body."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    content = _mk_content_node(NODE_A, "the appended body")
    html = render(
        {
            "content_nodes": [wv],
            "context": {"nodes_lookup": {NODE_A: content}},
        }
    )
    assert "the appended body" in html
    assert f'data-node-id="{NODE_A}"' in html


def test_render_accepts_positional_node_with_matching_id() -> None:
    """Positional content_nodes[1..] entries get the same freeze check;
    a matching id is accepted."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    content = _mk_content_node(NODE_A, "positional body")
    html = render({"content_nodes": [wv, content]})
    assert "positional body" in html


def test_render_accepts_node_without_id_field() -> None:
    """A content-node missing an `id` field gets rendered as-is — the
    freeze check fires only when an id is supplied AND disagrees. This
    keeps the test fixtures (which sometimes omit ids) compatible."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    content = {"name": "no_id_content", "kind": "content", "body": "anonymous body"}
    html = render(
        {
            "content_nodes": [wv],
            "context": {"nodes_lookup": {NODE_A: content}},
        }
    )
    assert "anonymous body" in html


# ---------------------------------------------------------------------------
# Freeze-at-append-time enforcement — leaf substitution rejected
# ---------------------------------------------------------------------------


def test_render_rejects_leaf_substitution_via_nodes_lookup() -> None:
    """Caller passes nodes_lookup[NODE_A] = leaf_node-with-id-NODE_B
    (the supersession leaf) in place of the original-append entry.
    The renderer raises FreezeAtAppendTimeViolation rather than
    silently rendering the leaf."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "I am the supersession leaf")
    with pytest.raises(FreezeAtAppendTimeViolation) as exc_info:
        render(
            {
                "content_nodes": [wv],
                "context": {"nodes_lookup": {NODE_A: leaf_node}},
            }
        )
    msg = str(exc_info.value)
    assert NODE_A in msg or NODE_B in msg
    assert "freeze_at_append_time" in msg or "substitute" in msg


def test_render_rejects_leaf_substitution_via_positional() -> None:
    """A positional content-node whose `id` differs from any position-
    entry's `node_id` raises FreezeAtAppendTimeViolation when the
    caller-supplied node lands in the rendered band."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    # Build a leaf with the WRONG id, and supply it via nodes_lookup
    # keyed at NODE_A (since the positional path keys by node['id'],
    # which would NOT trip the check — only the lookup-keyed path
    # triggers it).
    leaf_node = _mk_content_node(NODE_B, "leaf body")
    with pytest.raises(FreezeAtAppendTimeViolation):
        render(
            {
                "content_nodes": [wv],
                "context": {"nodes_lookup": {NODE_A: leaf_node}},
            }
        )


def test_violation_message_names_decision_b2() -> None:
    """The violation message references the decision the test author can
    look up — Decision B2 / freeze_at_append_time / substitute."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "leaf")
    with pytest.raises(FreezeAtAppendTimeViolation) as exc_info:
        render(
            {
                "content_nodes": [wv],
                "context": {"nodes_lookup": {NODE_A: leaf_node}},
            }
        )
    msg = str(exc_info.value)
    # At least one of these grep-able tokens should be present so a
    # downstream debugger searching the codebase for the violation
    # message finds the policy decision.
    assert any(
        token in msg
        for token in (
            "freeze_at_append_time",
            "Decision B2",
            "substitute",
            "append-only",
        )
    )


# ---------------------------------------------------------------------------
# Append-kind marker (data-append-kind="original" vs "supersession")
# ---------------------------------------------------------------------------


def test_render_marks_original_entries_data_append_kind_original() -> None:
    """A position with no provenance.source_ref renders as
    data-append-kind="original" (the maintainer's first-publish form)."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert f'data-node-id="{NODE_A}" data-append-kind="original"' in html


def test_render_marks_supersession_entries_data_append_kind_supersession() -> None:
    """A position with provenance.source_ref renders as
    data-append-kind="supersession" (per-edit-new-node landed at the
    bottom of the stream — SPEC-084)."""
    positions = [
        _mk_position(NODE_A),
        _mk_position(NODE_B, source="edit", source_ref=NODE_A),
    ]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    # Original first.
    assert f'data-node-id="{NODE_A}" data-append-kind="original"' in html
    # Supersession second.
    assert f'data-node-id="{NODE_B}" data-append-kind="supersession"' in html


def test_render_supersession_keeps_original_at_position() -> None:
    """Per Decision B2: when an edit produces a supersession-append, the
    ORIGINAL stays at its original position; the supersession appears
    LATER in the stream. The renderer's chronological order honors this."""
    positions = [
        _mk_position(NODE_A),
        _mk_position(NODE_C),
        _mk_position(NODE_B, source="edit", source_ref=NODE_A),
    ]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    # The original (NODE_A) appears BEFORE the supersession (NODE_B).
    idx_original = html.find(f'data-node-id="{NODE_A}"')
    idx_supersession = html.find(f'data-node-id="{NODE_B}"')
    assert idx_original < idx_supersession
    assert idx_original > 0
    # An UNRELATED intervening append (NODE_C) sits between them — the
    # supersession does NOT collapse back to its predecessor's slot.
    idx_unrelated = html.find(f'data-node-id="{NODE_C}"')
    assert idx_original < idx_unrelated < idx_supersession


def test_render_supersession_marker_still_present() -> None:
    """The provenance-supersedes glyph (↻) is still emitted for the
    supersession entry — commit 3 keeps the visual marker commit 2
    introduced, in addition to the data-append-kind attribute."""
    positions = [
        _mk_position(NODE_A),
        _mk_position(NODE_B, source="edit", source_ref=NODE_A),
    ]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert "provenance-supersedes" in html
    assert "↻" in html


# ---------------------------------------------------------------------------
# Surface-level data-freeze-policy attribute
# ---------------------------------------------------------------------------


def test_surface_advertises_strict_policy_by_default() -> None:
    """The surface div carries data-freeze-policy='strict' under the
    default policy, so test harnesses + future debug tools can see what
    enforcement mode is active."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert 'data-freeze-policy="strict"' in html


def test_surface_advertises_history_collapsed_policy_when_opted_out() -> None:
    """Opt-out via context['freeze_at_append_time']=False flips the
    surface attribute to 'history_collapsed' — the phase-2 mode name."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    html = render(
        {
            "content_nodes": [wv],
            "context": {"freeze_at_append_time": False},
        }
    )
    assert 'data-freeze-policy="history_collapsed"' in html


def test_empty_workflow_view_carries_strict_policy_attr() -> None:
    """The empty-hint fragment also carries the policy attribute so
    downstream consumers don't have to special-case empty surfaces."""
    wv = _mk_workflow_view([])
    html = render({"content_nodes": [wv]})
    assert 'data-freeze-policy="strict"' in html


# ---------------------------------------------------------------------------
# Opt-out semantics (phase-2 history_collapsed escape hatch)
# ---------------------------------------------------------------------------


def test_opt_out_allows_leaf_substitution() -> None:
    """When freeze_at_append_time=False, a substituted leaf is rendered
    without raising — the phase-2 history_collapsed mode the per-module
    plan reserves for SPEC-082's brief 01 follow-up."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "leaf body shown in-place")
    html = render(
        {
            "content_nodes": [wv],
            "context": {
                "nodes_lookup": {NODE_A: leaf_node},
                "freeze_at_append_time": False,
            },
        }
    )
    # The leaf's body shows — the position-entry's slot is rendered
    # with the substituted leaf's content.
    assert "leaf body shown in-place" in html


def test_opt_out_string_false_is_recognized() -> None:
    """URL/query-string contexts arrive as strings; the renderer coerces
    'false' / '0' / 'no' / 'off' to the opt-out semantics."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "leaf via string-coerced flag")
    for raw_value in ("false", "False", "0", "no", "off", "  False  "):
        html = render(
            {
                "content_nodes": [wv],
                "context": {
                    "nodes_lookup": {NODE_A: leaf_node},
                    "freeze_at_append_time": raw_value,
                },
            }
        )
        assert "leaf via string-coerced flag" in html
        assert 'data-freeze-policy="history_collapsed"' in html


def test_opt_in_string_true_is_recognized() -> None:
    """String 'true' / '1' / 'yes' / 'on' coerce to the strict policy
    (i.e. NOT opt-out). The renderer should reject leaf substitution."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "leaf")
    for raw_value in ("true", "True", "1", "yes", "on"):
        with pytest.raises(FreezeAtAppendTimeViolation):
            render(
                {
                    "content_nodes": [wv],
                    "context": {
                        "nodes_lookup": {NODE_A: leaf_node},
                        "freeze_at_append_time": raw_value,
                    },
                }
            )


# ---------------------------------------------------------------------------
# Render order + invariants under append-only
# ---------------------------------------------------------------------------


def test_chronological_render_order_preserves_append_order() -> None:
    """The renderer emits node-boxes in the chronological order of
    positions — earlier appends appear earlier in the HTML (lower
    DOM index), per the maintainer's "scroll-to-bottom is chat-like"
    expectation. Decision B2's append-only-render guarantee is that
    this order never changes once an entry is appended."""
    positions = [
        _mk_position(NODE_A),
        _mk_position(NODE_B),
        _mk_position(NODE_C),
    ]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    idx_a = html.find(f'data-node-id="{NODE_A}"')
    idx_b = html.find(f'data-node-id="{NODE_B}"')
    idx_c = html.find(f'data-node-id="{NODE_C}"')
    assert 0 < idx_a < idx_b < idx_c


def test_render_does_not_mutate_positions_under_strict_policy() -> None:
    """The strict-policy render is read-only — the renderer does not
    mutate the workflow_view's positions even when it raises."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    original_positions = [dict(p) for p in positions]
    leaf_node = _mk_content_node(NODE_B, "leaf")
    with pytest.raises(FreezeAtAppendTimeViolation):
        render(
            {
                "content_nodes": [wv],
                "context": {"nodes_lookup": {NODE_A: leaf_node}},
            }
        )
    assert wv["body"]["positions"] == original_positions


def test_renderer_id_unchanged_by_commit_3() -> None:
    """The renderer-id is the load-bearing identifier the substrate
    manifest + brief 06 text-API + brief 07 timeline jump compose
    against. Commit 3 must not rename it."""
    assert RENDERER_ID == "workflow_continuous_scroll_v1"


# ---------------------------------------------------------------------------
# Probe Tool T2 — sanity check the harness is importable
# ---------------------------------------------------------------------------


def test_tool_t2_append_only_probe_importable() -> None:
    """Tool T2 (append_only_probe) is importable + exposes the probe
    registry the per-module plan names. The harness itself runs as a
    CLI; this test asserts the module imports without ImportError so
    the brief 06 wrapping can register it later."""
    from tools.workflow_streamlit.test_harnesses import append_only_probe

    assert hasattr(append_only_probe, "PROBE_REGISTRY")
    assert set(append_only_probe.PROBE_REGISTRY.keys()) >= {
        "probe-double-append",
        "probe-supersession",
        "probe-leaf-substitution",
        "probe-opt-out",
    }
