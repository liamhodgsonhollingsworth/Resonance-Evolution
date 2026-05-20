"""
ButtonNode — first-class button as a scene-graph node (SPEC-077).

Each ButtonNode is a metadata node attached (via ``params['parent']``) to
some other node. The GUI shell's button-row builder reads ButtonNodes off
``engine.nodes`` at render time; the engine-actions dispatch routes the
button's click through ``engine.actions.dispatch_action`` after resolving
the button's ``target`` prefix.

The design is intentionally minimal: a ButtonNode has no visual emit of
its own (the visible widget is drawn by the GUI shell or the per-panel
button-row code). ``describe`` returns a one-line summary so the
text-API can introspect the row.

Composes with:

- SPEC-076 derived-view: the Author / History / Connections "standards"
  on every node are NOT spawned ButtonNodes (see
  :func:`tools.button_view.button_row_for`) — they're computed on
  demand. Real ButtonNodes only exist for maintainer-added decorations
  AND for explicit standard-overrides.
- SPEC-067 view-registry: a ``target="view:<name>"`` button switches
  the active view via the shell's ``set_view`` (when a shell is
  attached).
- SPEC-068 chat-target routing: a ``target="session:<id>"`` button
  routes the dispatched action through the active-sessions surface.
- SPEC-054 paste trust-gate: pasting a ButtonNode snippet runs through
  the same trust-gate as any other node-type paste (no special
  handling needed at the paste surface).
- SPEC-073 module clipboard: the standard JSON serializer round-trips
  ButtonNode without changes.
- SPEC-069 visual_contract (optional, soft): if a ``visual_contract``
  module is available the GUI shell resolves icons through it; if not,
  icons are surfaced as the raw name string and the GUI falls back to
  a label-only rendering.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


# v1 fixed icon-name set per design §1. The GUI shell may resolve these
# through SPEC-069's visual_contract registry when available, but the
# names are valid as-is so unknown / unresolved icons fall back to
# label-only rendering rather than crashing the row.
KNOWN_ICONS = {
    "clock-rewind",  # History
    "graph",          # Connections
    "author",         # Author
    "lock",           # Lock
    "copy",           # Copy
    "paste",          # Paste
    "archive",        # Archive
    "pin",            # Pin
    "properties",     # Properties
}


def manifest() -> Manifest:
    return Manifest(
        name="ButtonNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            "label": "string",
            "icon": "string",
            "action": "string",
            "target": "string",
            "payload": "dict",
            "position": "string",
            "order": "int",
            "parent": "string",
            "standard": "bool",
            "hidden": "bool",
        },
        outputs={},
        description=(
            "A button decoration attached to a node (params.parent). "
            "Carries an action name + target hint dispatched through "
            "engine.actions.dispatch_action when clicked. The button's "
            "visible widget is rendered by the GUI shell's button-row "
            "code — this node owns only the data."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    """Validate and normalise the params dict.

    Every field is optional; the defaults match the design table in
    ``notes/designs/spec_076_077_buttons_as_nodes_design_2026_05_20.md``.

    ``payload`` and the various string fields are stored as plain dicts
    / strs so the standard JSON serializer round-trips without needing
    a custom encoder. The ``standard`` flag distinguishes built-in
    decorators from maintainer-added customizations; in v1 only
    explicit standard-overrides set this to True (the row-builder
    surfaces the implicit standards via a derived-view).
    """
    payload = params.get("payload", {}) or {}
    if not isinstance(payload, dict):
        payload = {}
    return {
        "label": str(params.get("label", "")),
        "icon": str(params.get("icon", "")),
        "action": str(params.get("action", "")),
        "target": str(params.get("target", "")),
        "payload": dict(payload),
        "position": str(params.get("position", "row")),
        "order": int(params.get("order", 0)),
        "parent": str(params.get("parent", "")),
        "standard": bool(params.get("standard", False)),
        "hidden": bool(params.get("hidden", False)),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Buttons never recurse — they have no rendered children."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """No visual output — the GUI shell renders the button widget.

    Returning a transparent / zero channel pair keeps the engine's
    default compositor happy; a ButtonNode wired into a scene as a
    render target (unusual but legal) contributes nothing instead of
    crashing. The text-API observation surface is :func:`describe`.
    """
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API."""
    label = state.get("label", "") or "(no label)"
    parent = state.get("parent") or "(detached)"
    action = state.get("action") or "(no action)"
    target = state.get("target") or "(self)"
    flags = []
    if state.get("standard"):
        flags.append("standard")
    if state.get("hidden"):
        flags.append("hidden")
    flag_tag = f" [{','.join(flags)}]" if flags else ""
    return (
        f"ButtonNode({label!r}) parent={parent} action={action} "
        f"target={target}{flag_tag}"
    )


# ---------------------------------------------------------------------------
# Helper consumed by the row-builder + click-dispatch layer.
# ---------------------------------------------------------------------------


def resolve_icon(icon_name: str) -> Optional[str]:
    """Resolve an icon name to a display string.

    Soft-fails when SPEC-069's ``visual_contract`` module is unavailable
    — the design explicitly says the two specs land in parallel. If the
    module is importable AND exposes a ``resolve_icon`` callable, defer
    to it; otherwise fall back to the known-icons set or the raw name.

    Returns ``None`` when the icon is empty / unknown, so the GUI shell
    can render a label-only button.
    """
    if not icon_name:
        return None
    try:
        from tools import visual_contract  # type: ignore[import-not-found]
    except Exception:
        visual_contract = None  # type: ignore[assignment]
    if visual_contract is not None and hasattr(visual_contract, "resolve_icon"):
        try:
            resolved = visual_contract.resolve_icon(icon_name)
            if resolved:
                return resolved
        except Exception:
            # Defensive: a broken visual_contract module must not break
            # button rendering. Fall through to the local registry.
            pass
    if icon_name in KNOWN_ICONS:
        return icon_name
    # Unknown icon — surface the name but let the caller decide whether
    # to render. The GUI shell drops to label-only when this returns the
    # raw name and the renderer can't find a glyph for it.
    return icon_name
