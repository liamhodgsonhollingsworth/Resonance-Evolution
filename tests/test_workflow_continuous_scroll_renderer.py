"""test_workflow_continuous_scroll_renderer.py — tests for the renderer.

Per brief 02 commit 2 (Decision B1, SPEC-086 + SPEC-082).

Covers:
- `render({...})` accepts a renderer-spec-shaped input and emits HTML.
- The renderer rejects malformed inputs (non-list content_nodes, missing
  workflow_view, wrong kind).
- Empty workflow_view → empty-hint fragment with no node-boxes.
- Populated workflow_view → 70-node DOM-bounded output per the
  50+20+20 default window (when positions > 90 entries).
- Anchor mode — the target node is in the visible band.
- Window override (?window=...) — the band sizes change per spec.
- Pre-fetched content nodes appear in the rendered box; absent ids get
  data-placeholder="true".
- The output fragment carries the substrate-dispatch hooks
  (data-renderer, data-workflow-view-id, data-window).
- `render_legacy()` produces the same fragment via the legacy calling shape.

The renderer is invoked DIRECTLY (no Streamlit panel context); the
panel-level integration is tested via the existing
`test_workflow_view_substrate_mirror.py` test-fixture pattern.

Run:
    cd Apeiron && python -m pytest tests/test_workflow_continuous_scroll_renderer.py -v
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import (  # noqa: E402
    RENDERER_ID,
    render,
    render_legacy,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mk_position(node_id: str, source: str = "test", source_ref: str = "") -> dict:
    entry: dict = {
        "node_id": node_id,
        "appended_at": "2026-05-22T00:00:00Z",
        "appended_by": "test",
        "provenance": {"source": source},
    }
    if source_ref:
        entry["provenance"]["source_ref"] = source_ref
    return entry


def _mk_workflow_view(positions: list[dict], wv_id: str = "sha256:wv1") -> dict:
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
        "name": f"content_{node_id[:8]}",
        "kind": "content",
        "body": body_text,
    }


def _count_node_boxes(html: str) -> int:
    return html.count('class="node-box workflow-entry"')


def _count_placeholders(html: str) -> int:
    return html.count('data-placeholder="true"')


# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------


def test_render_rejects_non_dict_input() -> None:
    with pytest.raises(TypeError):
        render("not-a-dict")  # type: ignore[arg-type]


def test_render_rejects_non_list_content_nodes() -> None:
    with pytest.raises(TypeError):
        render({"content_nodes": "not-a-list"})


def test_render_rejects_empty_content_nodes() -> None:
    with pytest.raises(ValueError):
        render({"content_nodes": []})


def test_render_rejects_non_dict_first_entry() -> None:
    with pytest.raises(ValueError):
        render({"content_nodes": ["not-a-dict"]})


def test_render_rejects_wrong_kind_first_entry() -> None:
    not_a_workflow_view = {
        "id": "x",
        "kind": "renderer",
        "body": {"positions": []},
    }
    with pytest.raises(ValueError) as exc_info:
        render({"content_nodes": [not_a_workflow_view]})
    assert "workflow_view" in str(exc_info.value)


def test_render_rejects_non_dict_body() -> None:
    bad = {"id": "x", "kind": "workflow_view", "body": "raw string"}
    with pytest.raises(ValueError):
        render({"content_nodes": [bad]})


def test_render_rejects_non_dict_context() -> None:
    wv = _mk_workflow_view([])
    with pytest.raises(TypeError):
        render({"content_nodes": [wv], "context": "not-a-dict"})


# ---------------------------------------------------------------------------
# Empty workflow_view → empty hint
# ---------------------------------------------------------------------------


def test_render_empty_workflow_view_shows_empty_hint() -> None:
    wv = _mk_workflow_view([])
    html = render({"content_nodes": [wv]})
    assert "empty-hint" in html
    assert _count_node_boxes(html) == 0
    # Surface shell still present so JS can attach.
    assert 'data-renderer="workflow_continuous_scroll_v1"' in html


def test_render_empty_workflow_view_includes_inline_styles() -> None:
    wv = _mk_workflow_view([])
    html = render({"content_nodes": [wv]})
    assert "<style>" in html
    assert ".workflow-scroll" in html


# ---------------------------------------------------------------------------
# Populated workflow_view → sliding window
# ---------------------------------------------------------------------------


def test_render_100_node_workflow_emits_70_boxes_default_window() -> None:
    """100 entries, default 50+20+20 + scroll-to-bottom: visible 50 + buffer-above 20 = 70 in DOM."""
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(100)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert _count_node_boxes(html) == 70


def test_render_DOM_size_smaller_than_total_positions() -> None:
    """The renderer must NOT render every position when count > window."""
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(1000)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    # DOM should be visible + buffer (70) — NOT 1000.
    assert _count_node_boxes(html) == 70
    # Carries the position count for the JS layer to see.
    assert 'data-positions-count="1000"' in html
    assert 'data-rendered-count="70"' in html


def test_render_short_workflow_renders_all_entries() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(10)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert _count_node_boxes(html) == 10


# ---------------------------------------------------------------------------
# Anchor mode
# ---------------------------------------------------------------------------


def test_render_with_anchor_centers_window() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(100)]
    anchor_node_id = positions[50]["node_id"]
    wv = _mk_workflow_view(positions)
    html = render(
        {"content_nodes": [wv], "context": {"anchor": anchor_node_id}}
    )
    # The anchor's node_id appears as a data-node-id on the box.
    assert f'data-node-id="{anchor_node_id}"' in html
    # With anchor in middle: visible 50 + buffer_above 20 + buffer_below 20 = 90 boxes.
    assert _count_node_boxes(html) == 90


def test_render_with_unknown_anchor_raises() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(10)]
    wv = _mk_workflow_view(positions)
    with pytest.raises(ValueError):
        render(
            {
                "content_nodes": [wv],
                "context": {"anchor": "sha256:not-in-positions"},
            }
        )


# ---------------------------------------------------------------------------
# Window override
# ---------------------------------------------------------------------------


def test_render_window_override_csv_changes_band_sizes() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(100)]
    wv = _mk_workflow_view(positions)
    html = render(
        {"content_nodes": [wv], "context": {"window": "10,5,5"}}
    )
    # scroll-to-bottom default + window=(10,5,5): visible 10 + buffer-above 5 = 15.
    assert _count_node_boxes(html) == 15
    assert 'data-window="10,5,5"' in html


def test_render_window_override_with_anchor() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(100)]
    anchor_node_id = positions[50]["node_id"]
    wv = _mk_workflow_view(positions)
    html = render(
        {
            "content_nodes": [wv],
            "context": {"anchor": anchor_node_id, "window": "10,5,5"},
        }
    )
    # visible 10 + buffer_above 5 + buffer_below 5 = 20.
    assert _count_node_boxes(html) == 20


def test_render_metadata_window_used_when_no_override() -> None:
    """When context.window is absent, the renderer falls back to
    workflow_view.metadata.window."""
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(100)]
    wv = _mk_workflow_view(positions)
    wv["body"]["metadata"]["window"] = "5,2,2"
    html = render({"content_nodes": [wv]})
    # scroll-to-bottom + (5, 2, 2) → 5 visible + 2 buffer_above = 7.
    assert _count_node_boxes(html) == 7


# ---------------------------------------------------------------------------
# Pre-fetched content nodes
# ---------------------------------------------------------------------------


def test_render_pre_fetched_node_includes_body() -> None:
    nid = "sha256:abcd" + "0" * 60
    positions = [_mk_position(nid)]
    wv = _mk_workflow_view(positions)
    content = _mk_content_node(nid, "Hello workflow")
    html = render({"content_nodes": [wv, content]})
    assert "Hello workflow" in html
    assert _count_placeholders(html) == 0


def test_render_unfetched_node_uses_placeholder() -> None:
    nid = "sha256:abcd" + "0" * 60
    positions = [_mk_position(nid)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert _count_placeholders(html) == 1


def test_render_context_nodes_lookup_wins_over_positional() -> None:
    nid = "sha256:abcd" + "0" * 60
    positions = [_mk_position(nid)]
    wv = _mk_workflow_view(positions)
    positional = _mk_content_node(nid, "POSITIONAL")
    lookup_node = _mk_content_node(nid, "LOOKUP")
    html = render(
        {
            "content_nodes": [wv, positional],
            "context": {"nodes_lookup": {nid: lookup_node}},
        }
    )
    assert "LOOKUP" in html
    assert "POSITIONAL" not in html


# ---------------------------------------------------------------------------
# Substrate-dispatch hooks
# ---------------------------------------------------------------------------


def test_render_emits_substrate_dispatch_hooks() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(5)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert f'data-renderer="{RENDERER_ID}"' in html
    assert 'data-workflow-view-id="sha256:wv1"' in html
    assert 'data-window=' in html


def test_render_emits_workflow_scroll_namespace_script() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(5)]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert "window.__workflow_scroll" in html
    assert "ns.renderer_id" in html


def test_render_provenance_supersedes_marker_present() -> None:
    """A supersession-append entry (provenance.source_ref) shows the
    supersedes marker for the position-anchored rendering per Decision B2."""
    positions = [
        _mk_position("sha256:a" + "0" * 63),
        _mk_position(
            "sha256:b" + "0" * 63,
            source="edit",
            source_ref="sha256:a" + "0" * 63,
        ),
    ]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    assert "provenance-supersedes" in html
    assert "↻" in html


# ---------------------------------------------------------------------------
# render_legacy adapter
# ---------------------------------------------------------------------------


def test_render_legacy_produces_same_fragment_as_render() -> None:
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(5)]
    wv = _mk_workflow_view(positions)
    via_render = render({"content_nodes": [wv]})
    via_legacy = render_legacy(renderer_node={}, content_nodes=[wv])
    assert via_render == via_legacy


# ---------------------------------------------------------------------------
# Position-anchored rendering (Decision B2 storage-layer foundation)
# ---------------------------------------------------------------------------


def test_render_supersession_append_renders_both_entries() -> None:
    """A supersession-append shows BOTH the original entry (at its
    position) AND the supersession (at the bottom of the stream).

    Per Decision B2: the storage layer (commit 1) allows both entries to
    coexist when the supersession-append carries a source_ref. This test
    asserts the renderer at commit 2 emits both — the explicit
    freeze-at-append-time policy lands in commit 3, but the position-
    anchored shape is in place now."""
    original = _mk_position("sha256:" + "a" * 63 + "1")
    supersession = _mk_position(
        "sha256:" + "b" * 63 + "1",
        source="edit",
        source_ref=original["node_id"],
    )
    positions = [original, supersession]
    wv = _mk_workflow_view(positions)
    html = render({"content_nodes": [wv]})
    # Both node-ids appear in the rendered HTML.
    assert f'data-node-id="{original["node_id"]}"' in html
    assert f'data-node-id="{supersession["node_id"]}"' in html


def test_render_does_not_mutate_input_positions() -> None:
    """The renderer is read-only; mutating the body's positions list is
    a contract violation."""
    positions = [_mk_position(f"sha256:{i:064x}") for i in range(5)]
    wv = _mk_workflow_view(positions)
    original_positions = [dict(p) for p in positions]
    render({"content_nodes": [wv]})
    # Body unchanged.
    assert wv["body"]["positions"] == original_positions


# ---------------------------------------------------------------------------
# Renderer-spec validation — the manifest at substrate/nodes/<hex>.md
# ---------------------------------------------------------------------------


def test_renderer_spec_manifest_is_published() -> None:
    """The brief 02 commit 2 substrate manifest is at the content-addressed
    path computed from the renderer-spec body. This test asserts the
    manifest file exists and is the one this commit ships."""
    expected_hex = "a0ed348e5ecf8cf536b358877c5fa0144bb0fe2f4c1e391f6908f75931f83094"
    manifest_path = (
        APEIRON_ROOT.parent
        / "Alethea"
        / "Alethea-cc"
        / "substrate"
        / "nodes"
        / f"{expected_hex}.md"
    )
    assert manifest_path.exists(), (
        f"workflow_continuous_scroll_v1 manifest missing at {manifest_path}"
    )
    text = manifest_path.read_text(encoding="utf-8")
    assert "workflow_continuous_scroll_v1" in text
    assert "renderer-spec" in text
    assert "kind: renderer" in text
