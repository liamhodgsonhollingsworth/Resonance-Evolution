"""workflow_continuous_scroll_v1 — Streamlit-side continuous-scroll renderer.

Per brief 02 commit 2 (Decision B1, SPEC-086 + SPEC-082).

Consumes a workflow_view substrate node (kind: workflow_view; body-format:
workflow-view; published by brief 02 commit 1 + extended by every append
action) plus a viewport context, and emits an HTML fragment containing the
visible + buffer-band node boxes.

The Streamlit panel `panels/workflow_continuous_scroll_panel.py` wraps
this fragment via `st.markdown(html, unsafe_allow_html=True)` and mounts
at MOUNT_MAIN. The literal-domain renderer (brief 02 commit 7) lives in
`Resonance-Website/renderers/workflow_continuous_scroll_v1.py` and reuses
this module's pure-function helpers (extracted in `sliding_window.py`).

Substrate dispatch:
  `execute(renderer_node, {"content_nodes": [workflow_view, *contents],
  "context": {...}})` reaches `render(input)` via the
  `kind: renderer` handler installed by brief 01 commit 1.

Composed against:
  - `sliding_window.select_window()` — band-selection (pure function).
  - The `workflow_view` substrate body-format (commit 1) — the renderer
    reads `body.positions`, `body.default_paste_location`,
    `body.metadata.window` only; never mutates.
  - The existing `_make_box`-style "node-box with author + history
    buttons" pattern (Resonance-Website `_shared._make_box`). The
    Streamlit-side fragment uses a thinner shell since the surrounding
    Streamlit page already provides chrome.
"""
from __future__ import annotations

from html import escape
from typing import Any, Dict, List, Optional

# Imported via relative import when the module is invoked from inside
# the workflow_streamlit package; falls back to a path-based import for
# direct-execution test harnesses + the substrate's dynamic loader.
try:
    from .sliding_window import (
        DEFAULT_VISIBLE,
        parse_window_param,
        select_window,
    )
except ImportError:  # pragma: no cover - import path differs in substrate dispatch
    import sys
    from pathlib import Path

    _HERE = Path(__file__).resolve().parent
    if str(_HERE) not in sys.path:
        sys.path.insert(0, str(_HERE))
    from sliding_window import (  # type: ignore
        DEFAULT_VISIBLE,
        parse_window_param,
        select_window,
    )


RENDERER_ID = "workflow_continuous_scroll_v1"


# ---------------------------------------------------------------------------
# Decision B2 — freeze-at-append-time policy default + violation type
# ---------------------------------------------------------------------------
#
# Per the per-module plan (commit 3): the renderer enforces that every
# entry in the workflow_view's positions list renders the version frozen
# at append-time. The substrate's content-addressing guarantees this
# whenever the caller supplies the byte-stable version that was appended
# at the original `node_id`; the renderer's job is to refuse any silent
# substitution (e.g. a caller passing a supersession leaf via
# `nodes_lookup` in place of the original-append entry).
#
# The default policy is `freeze_at_append_time=True`. Callers may opt
# out via `context['freeze_at_append_time']=False` — but the only valid
# opt-out is brief 01's planned `history_collapsed` mode (phase-2), in
# which supersessions render IN-PLACE of their predecessor. Phase-1
# ships the strict policy.

DEFAULT_FREEZE_AT_APPEND_TIME = True


class FreezeAtAppendTimeViolation(ValueError):
    """Raised when the renderer is asked to substitute a node version
    for an already-appended position.

    Per Decision B2 (SPEC-086, brief 02 per-module plan): the renderer
    enforces that each position renders the version frozen at append-
    time. A caller-supplied `nodes_lookup` entry whose `id` disagrees
    with the position-entry's `node_id` is a contract violation — it
    means the caller is trying to render a supersession leaf in place
    of the original-append entry. Raised by `_render_node_box` and
    propagated out of `render()`.

    Subclasses `ValueError` so existing callers' broad-exception handlers
    still catch it; the named subclass lets tests + the append-only
    probe (Tool T2) distinguish freeze-violations from other render-time
    errors.
    """


# ---------------------------------------------------------------------------
# Workflow_view extraction
# ---------------------------------------------------------------------------


def _extract_workflow_view(content_nodes: List[dict]) -> dict:
    """Return the workflow_view body. Raises ValueError if the first
    entry is not a workflow_view substrate node.
    """
    if not isinstance(content_nodes, list) or not content_nodes:
        raise ValueError(
            f"{RENDERER_ID}: content_nodes must be a non-empty list with the "
            f"workflow_view substrate node first; got "
            f"{type(content_nodes).__name__}"
        )
    first = content_nodes[0]
    if not isinstance(first, dict):
        raise ValueError(
            f"{RENDERER_ID}: content_nodes[0] must be a dict (the workflow_view); "
            f"got {type(first).__name__}"
        )
    if first.get("kind") != "workflow_view":
        raise ValueError(
            f"{RENDERER_ID}: content_nodes[0] must have kind 'workflow_view'; "
            f"got {first.get('kind')!r}"
        )
    body = first.get("body")
    if not isinstance(body, dict):
        raise ValueError(
            f"{RENDERER_ID}: workflow_view body must be a parsed dict "
            f"(body-format workflow-view); got {type(body).__name__}"
        )
    return body


def _build_nodes_lookup(
    content_nodes: List[dict], context_lookup: Optional[Dict[str, dict]]
) -> Dict[str, dict]:
    """Build a node_id -> node-dict map.

    Composes the (optional) context['nodes_lookup'] with any extra
    content_nodes the caller passed in positions [1..]. Caller-supplied
    lookups win over positional entries on collision.
    """
    out: Dict[str, dict] = {}
    for n in content_nodes[1:]:
        if isinstance(n, dict):
            nid = n.get("id")
            if isinstance(nid, str):
                out[nid] = n
    if isinstance(context_lookup, dict):
        for k, v in context_lookup.items():
            if isinstance(k, str) and isinstance(v, dict):
                out[k] = v
    return out


# ---------------------------------------------------------------------------
# Per-node rendering — minimal HTML for the Streamlit-side fragment
# ---------------------------------------------------------------------------


def _render_node_box(
    node_id: str,
    node: Optional[dict],
    position_entry: dict,
    freeze_at_append_time: bool = True,
) -> str:
    """Render a single workflow entry as a node-box.

    When `node` is None (the caller did not supply the body), render a
    placeholder skeleton with `data-placeholder="true"` so the JS layer
    can lazy-fill later. When supplied, render the body via the simplest
    text-pass (the deep brief 03 visual treatment supersedes this fragment
    via the per-kind primitives the commit 4+ paste-dispatch + commit 7
    literal-domain renderer compose).

    Per Decision B2 (commit 3): the renderer renders the version frozen
    at append-time. When `freeze_at_append_time=True` (default), the
    `node`'s `id` is validated against the position-entry's `node_id`
    BEFORE the body is emitted. If they disagree, the renderer raises
    `FreezeAtAppendTimeViolation` rather than silently rendering the
    leaf — this is the enforcement that distinguishes commit 3 from
    commit 2's permissive position-anchored rendering. The validation
    fires at the per-node-box layer so violations are localized to the
    offending entry.

    Content-addressing already guarantees that looking up `node_id` in
    the substrate returns the byte-stable version appended at that
    position; the policy here enforces that the renderer never accepts
    a SUBSTITUTED node (e.g., a supersession leaf passed in via
    `nodes_lookup`) for the original position.

    A position entry whose `provenance.source_ref` names a predecessor
    gets a `data-append-kind="supersession"` marker; original-append
    entries get `data-append-kind="original"`. Both are emitted in
    chronological-append order — supersessions land at the bottom of
    the stream, NOT in-place of their predecessor.
    """
    appended_at = position_entry.get("appended_at", "")
    provenance = position_entry.get("provenance") or {}
    source = provenance.get("source", "")
    source_ref = provenance.get("source_ref")
    append_kind = "supersession" if (
        isinstance(source_ref, str) and source_ref
    ) else "original"

    # Freeze-at-append-time enforcement (Decision B2 + SPEC-086).
    # When the caller supplies a `node`, its `id` MUST match the
    # `node_id` recorded in the position entry. The renderer refuses to
    # substitute a leaf version for the originally-appended version —
    # that would silently break the append-only invariant the maintainer
    # depends on.
    if freeze_at_append_time and node is not None:
        supplied_id = node.get("id")
        if isinstance(supplied_id, str) and supplied_id and supplied_id != node_id:
            raise FreezeAtAppendTimeViolation(
                f"{RENDERER_ID}: nodes_lookup supplied node id "
                f"{supplied_id!r} for position {node_id!r}. Per Decision B2 "
                f"(freeze_at_append_time), the renderer refuses to substitute "
                f"a different version for an already-appended position. "
                f"Supersessions appear as NEW positions at the bottom of the "
                f"stream, NOT as in-place substitutions for prior positions. "
                f"To opt out, pass context['freeze_at_append_time']=False "
                f"(only the history_collapsed mode should do this — phase-2)."
            )

    if node is None:
        body_html = (
            '<div class="node-body placeholder">'
            f"<em>node {escape(node_id[:16])}… not pre-fetched</em>"
            "</div>"
        )
        placeholder_attr = ' data-placeholder="true"'
    else:
        body_html = _render_node_body(node)
        placeholder_attr = ""

    supersedes_marker = ""
    if append_kind == "supersession":
        supersedes_marker = (
            f'<span class="provenance-supersedes" title="supersedes '
            f'{escape(source_ref)}">↻</span>'
        )

    meta_html = (
        '<div class="node-meta">'
        f'<span class="ts">{escape(appended_at)}</span>'
        f'<span class="src">{escape(source)}</span>'
        f"{supersedes_marker}"
        "</div>"
    )

    return (
        f'<div class="node-box workflow-entry" data-node-id="{escape(node_id)}"'
        f' data-append-kind="{append_kind}"'
        f"{placeholder_attr}>"
        f"{meta_html}"
        f"{body_html}"
        "</div>"
    )


def _render_node_body(node: dict) -> str:
    """Render the body of a fetched content-node.

    Phase-1 behavior — minimal, kind-agnostic. The per-kind primitives
    (brief 03) supersede this with kind-specific renderers (text-node,
    image-node, link-node, code-node) once they land. For commit 2 the
    renderer keeps the rendering path simple: the body is treated as
    pre-formatted text and escaped.
    """
    body = node.get("body")
    if isinstance(body, str):
        return f'<pre class="node-body raw-body">{escape(body.strip())}</pre>'
    if isinstance(body, dict):
        # Show a compact JSON representation for dict-shaped bodies (typical
        # for renderer-spec, port-spec, workflow-view contents).
        import json as _json
        formatted = _json.dumps(body, indent=2, sort_keys=True)
        return f'<pre class="node-body json-body">{escape(formatted)}</pre>'
    return f'<pre class="node-body raw-body">{escape(repr(body))}</pre>'


# ---------------------------------------------------------------------------
# Fragment + script emission
# ---------------------------------------------------------------------------


def _render_band(
    band_ids: List[str],
    positions_by_id: Dict[str, dict],
    nodes_lookup: Dict[str, dict],
    band_class: str,
    freeze_at_append_time: bool = True,
) -> str:
    """Render a list of node-ids as adjacent node-boxes.

    Threads the `freeze_at_append_time` policy through to
    `_render_node_box`. A FreezeAtAppendTimeViolation raised by any
    per-box render propagates to the caller so the violation is visible
    at the test surface (no silent leaf substitution slips through to
    the user-visible HTML).
    """
    if not band_ids:
        return ""
    parts = [f'<div class="band {band_class}">']
    for nid in band_ids:
        position_entry = positions_by_id.get(nid, {})
        node = nodes_lookup.get(nid)
        parts.append(
            _render_node_box(
                nid, node, position_entry,
                freeze_at_append_time=freeze_at_append_time,
            )
        )
    parts.append("</div>")
    return "\n".join(parts)


def _build_positions_index(positions: List[dict]) -> Dict[str, dict]:
    """Map content_node_id -> position entry. When the same node_id
    appears more than once (supersession-append case), the LAST entry
    wins (which is also the chronologically newer one — supersession
    appends always land at the bottom)."""
    out: Dict[str, dict] = {}
    for entry in positions:
        if isinstance(entry, dict):
            nid = entry.get("node_id")
            if isinstance(nid, str):
                out[nid] = entry
    return out


def _renderer_script(workflow_view_id: str, window_param_str: str) -> str:
    """Emit the JS that wires lazy-load + URL-hash updates.

    Brief 02 commit 2 ships the SHELL: the script declares the renderer-
    surface contract (data-renderer attr, data-window attr) and exposes
    a `window.__workflow_scroll` namespace consumers can extend. The
    full lazy-load + paste handlers land in commits 4 + 5 + 7 + 8 (each
    commit composes against this shell rather than redefining it).

    The minimal phase-1 behavior:
      - Updates `window.location.hash` to the canonical deep-link form
        (`#workflow_continuous_scroll_v1/<workflow_view_id>?window=<w>`)
        on initial load.
      - Records the renderer-surface element under
        `window.__workflow_scroll.surface` so subsequent commits' JS can
        attach handlers without re-querying the DOM.
      - Provides a `__workflow_scroll.report_scroll(scroll_y)` hook that
        the lazy-load layer (commit 4) wires up to the CLI bridge.
    """
    safe_view_id = escape(workflow_view_id)
    safe_window = escape(window_param_str)
    return (
        "<script>\n"
        "(function(){\n"
        "  if (!window.__workflow_scroll) { window.__workflow_scroll = {}; }\n"
        "  var ns = window.__workflow_scroll;\n"
        f"  ns.renderer_id = '{RENDERER_ID}';\n"
        f"  ns.workflow_view_id = '{safe_view_id}';\n"
        f"  ns.window_param = '{safe_window}';\n"
        "  ns.surface = document.querySelector('.workflow-scroll');\n"
        f"  var hash = '#{RENDERER_ID}/' + ns.workflow_view_id"
        " + '?window=' + encodeURIComponent(ns.window_param);\n"
        "  try { if (window.location.hash !== hash) {"
        " window.history.replaceState(null, '', hash); } } catch (e) {}\n"
        "  ns.report_scroll = function(y) {"
        " /* lazy-load wiring lands in commit 4 */ };\n"
        "})();\n"
        "</script>"
    )


def _inline_styles() -> str:
    """Minimal inline CSS for the fragment.

    Brief 02 commit 2 keeps styling restrained — the deeper Claude-Design
    visual pass (suggestions_and_design_workflow.md) handles the
    polish later. Phase-1 just produces readable, scannable output.
    """
    return (
        "<style>\n"
        ".workflow-scroll {"
        " display: flex; flex-direction: column; gap: 0.5rem; }\n"
        ".workflow-scroll .band {"
        " display: flex; flex-direction: column; gap: 0.5rem; }\n"
        ".workflow-scroll .band.visible {"
        " border-left: 3px solid #4a4; padding-left: 0.5rem; }\n"
        ".workflow-scroll .band.buffer {"
        " opacity: 0.7; }\n"
        ".workflow-scroll .node-box {"
        " border: 1px solid #ccc; padding: 0.75rem; }\n"
        ".workflow-scroll .node-box.placeholder,"
        " .workflow-scroll .node-box[data-placeholder='true'] {"
        " border-style: dashed; color: #888; }\n"
        ".workflow-scroll .node-meta {"
        " font-size: 0.8rem; color: #777; margin-bottom: 0.25rem;"
        " display: flex; gap: 0.5rem; }\n"
        ".workflow-scroll .node-body { margin: 0; }\n"
        ".workflow-scroll .node-body.raw-body,"
        " .workflow-scroll .node-body.json-body {"
        " white-space: pre-wrap; font-family: ui-monospace, monospace;"
        " font-size: 0.9rem; }\n"
        ".workflow-scroll .provenance-supersedes {"
        " color: #4a4; font-weight: bold; cursor: help; }\n"
        "</style>"
    )


# ---------------------------------------------------------------------------
# render(input) — the substrate-callable entry point
# ---------------------------------------------------------------------------


def render(input: Dict[str, Any]) -> str:
    """Substrate-callable entry-point per renderer-spec input.schema.

    Returns an HTML FRAGMENT (no <html>/<head>/<body>). The Streamlit
    panel wraps it via `st.markdown(html, unsafe_allow_html=True)`; the
    literal-domain renderer (commit 7) wraps it in a full HTML document.
    """
    if not isinstance(input, dict):
        raise TypeError(
            f"{RENDERER_ID}.render requires a dict input "
            f"(per renderer-spec input.schema); got {type(input).__name__}"
        )
    content_nodes = input.get("content_nodes")
    if not isinstance(content_nodes, list):
        raise TypeError(
            f"{RENDERER_ID}.render: input['content_nodes'] must be a list; "
            f"got {type(content_nodes).__name__}"
        )
    context = input.get("context") or {}
    if not isinstance(context, dict):
        raise TypeError(
            f"{RENDERER_ID}.render: input['context'] must be a dict; "
            f"got {type(context).__name__}"
        )

    workflow_view_body = _extract_workflow_view(content_nodes)
    workflow_view_id = content_nodes[0].get("id", "")
    positions = workflow_view_body.get("positions") or []
    metadata = workflow_view_body.get("metadata") or {}

    # Resolve the freeze-at-append-time policy (Decision B2 commit 3).
    # The default is True (strict append-only render-mode). The only
    # valid opt-out is the phase-2 history_collapsed mode (NYI). Coerce
    # to bool defensively — context values may arrive as ints / strings
    # from URL parsing.
    raw_freeze = context.get(
        "freeze_at_append_time", DEFAULT_FREEZE_AT_APPEND_TIME
    )
    if isinstance(raw_freeze, str):
        freeze_at_append_time = raw_freeze.strip().lower() not in (
            "false", "0", "no", "off", ""
        )
    else:
        freeze_at_append_time = bool(raw_freeze)

    # Resolve the window param — context override wins over metadata default.
    raw_window = context.get("window") or metadata.get("window")
    visible_size, buffer_above_size, buffer_below_size = parse_window_param(raw_window)

    viewport_height = int(context.get("viewport_height", 800))
    if viewport_height <= 0:
        viewport_height = 800

    anchor = context.get("anchor")
    scroll_y = context.get("scroll_y")
    if isinstance(anchor, str) and anchor:
        anchor_or_scroll: Optional[Dict[str, Any]] = {"anchor": anchor}
    elif isinstance(scroll_y, (int, float)):
        anchor_or_scroll = {"scroll_y": scroll_y}
    else:
        anchor_or_scroll = None  # scroll-to-bottom default

    nodes_lookup = _build_nodes_lookup(content_nodes, context.get("nodes_lookup"))

    bands = select_window(
        positions=positions,
        anchor_or_scroll_position=anchor_or_scroll,
        viewport_height=viewport_height,
        window_param=(visible_size, buffer_above_size, buffer_below_size),
    )

    positions_by_id = _build_positions_index(positions)

    freeze_policy_attr = "strict" if freeze_at_append_time else "history_collapsed"

    # Empty workflow_view → show a friendly hint.
    if not positions:
        empty_hint = (
            '<div class="workflow-scroll" data-renderer="'
            f'{RENDERER_ID}" data-workflow-view-id="{escape(workflow_view_id)}"'
            f' data-freeze-policy="{freeze_policy_attr}">'
            '<div class="empty-hint">'
            "Workflow surface is empty. Paste content, type into chat, "
            "or wait for the Notion-mirror pump to populate."
            "</div>"
            "</div>"
        )
        return _inline_styles() + "\n" + empty_hint

    above_html = _render_band(
        bands["buffer_above"], positions_by_id, nodes_lookup, "buffer above",
        freeze_at_append_time=freeze_at_append_time,
    )
    visible_html = _render_band(
        bands["visible"], positions_by_id, nodes_lookup, "visible",
        freeze_at_append_time=freeze_at_append_time,
    )
    below_html = _render_band(
        bands["buffer_below"], positions_by_id, nodes_lookup, "buffer below",
        freeze_at_append_time=freeze_at_append_time,
    )

    window_param_str = f"{visible_size},{buffer_above_size},{buffer_below_size}"
    rendered_count = (
        len(bands["visible"]) + len(bands["buffer_above"]) + len(bands["buffer_below"])
    )
    total = len(positions)

    surface_open = (
        '<div class="workflow-scroll"'
        f' data-renderer="{RENDERER_ID}"'
        f' data-workflow-view-id="{escape(workflow_view_id)}"'
        f' data-window="{escape(window_param_str)}"'
        f' data-positions-count="{total}"'
        f' data-rendered-count="{rendered_count}"'
        f' data-freeze-policy="{freeze_policy_attr}">'
    )
    surface_close = "</div>"

    fragment = "\n".join(
        [
            _inline_styles(),
            surface_open,
            above_html,
            visible_html,
            below_html,
            surface_close,
            _renderer_script(workflow_view_id, window_param_str),
        ]
    )
    return fragment


def render_legacy(renderer_node: dict, content_nodes: list[dict]) -> str:
    """Legacy entry-point matching the pre-refactor `RENDERERS[rid](...)`
    calling shape. Wraps `render(input)`.

    Kept for symmetry with the brief 01 commit-2 refactor of the other
    renderers; the workflow surface does not currently consume this
    path (the Streamlit panel calls `render(input)` directly) but the
    parity keeps the renderer-node contract uniform.
    """
    return render({"content_nodes": content_nodes, "context": {}})


__all__ = [
    "RENDERER_ID",
    "DEFAULT_FREEZE_AT_APPEND_TIME",
    "FreezeAtAppendTimeViolation",
    "render",
    "render_legacy",
]
