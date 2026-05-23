"""ToolboxNode — default container with auto-flip-on-first-rendered-child
(N-F035, Decision A2, SPEC-091).

Brief 03 commit 2 of the Resonance website implementation arc — the
third foundational primitive. Every newly-instantiated visible
primitive starts life as a ToolboxNode (per the per-module plan's
Decision A2); adding the first child with ``as: rendered`` (i.e., not
``as: link``) auto-flips the toolbox into a typed container via a
supersession-shaped event (the new typed node carries
``supersedes: <toolbox-id>`` plus a delegated-from annotation).

The brief 03 per-module plan is explicit that the supersession side
of the auto-flip lives in the Alethea-cc substrate (per SPEC-026 +
SPEC-084 — the per-edit-new-node invariant) — this Apeiron primitive
is the runtime side that:

  1. Tracks ``contents`` (the ordered list of child references with
     their ``as: link | rendered`` annotation).
  2. Computes the inferred typed-kind via
     ``_toolbox_inference_rules.infer_typed_kind`` when the first
     rendered child is added.
  3. Surfaces a delegation hint (a state-delta the GUI shell + text-API
     read) that names the typed-kind the substrate should publish a
     supersession of.
  4. Logs "ambiguous toolbox content" entries when no rule matches —
     the maintainer surfaces these in the Ctrl-mode debug overlay
     (brief 05) to pick a typed-kind manually.

Verb shape ports verbatim from ``node_types/idea_queue.py`` — the
``add / up / down / delete / move`` grammar IS the maintainer's
chosen API for ordered-list verbs (and the GUI builder consumption
in brief 04 leans on this shape). Idea-queue persists to disk; the
toolbox keeps state in the engine view-state cache because contents
are node references (themselves persisted), not free text.

Per Decision A7 + the per-module plan's N-F035 emit step 4: a
toolbox's default emit renders the title + a grid of child mini-icons
in link form. Phase-1 (this commit) ships a minimal emit — black
background + a small title strip — so the primitive is usable in
isolation; the mini-icon grid lands in commit 3+ once the
preview-emitter convention has more primitives implementing it.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _get_font, _paste_onto_screen_rectangle

from node_types import _toolbox_inference_rules


DEFAULT_W_WORLD = 2.5
DEFAULT_H_WORLD = 2.0
DEFAULT_RESOLUTION_PX = 256

# Child ``as:`` enum. ``link`` = button-ish reference (mini-icon);
# ``rendered`` = full visual of the child drawn inside. Decision A2's
# auto-flip trigger is "first child added with ``as: rendered``."
CHILD_AS_KINDS = ("link", "rendered")


def manifest() -> Manifest:
    return Manifest(
        name="ToolboxNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # Geometry (matches BoxNode + TextBoxNode).
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Toolbox-specific.
            "title": "string",
            # Initial contents — list of dicts ``{node_id, as,
            # child_kind?}``. Phase-1 build clones it shallow + stores
            # in state; runtime mutations go through handle_action.
            "contents": "list",
            # Z-order + visual-variant override (per Decision A1).
            "layer": "int",
            "displayed_by": "string",
            # Background color (matches list_renderer convention).
            "background_color": "vec3",
            "title_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Default-container primitive (N-F035 / SPEC-091). Holds an "
            "ordered list of child references in linked or rendered form; "
            "adding the first rendered child surfaces an auto-flip hint "
            "naming the inferred typed-kind (Decision A2). Verb shape "
            "ports from idea_queue: add/up/down/delete/move."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    bg = params.get("background_color")
    if bg is None:
        bg = [0.12, 0.14, 0.20]
    title_color = params.get("title_color")
    if title_color is None:
        title_color = [0.92, 0.93, 0.88]

    # Normalize the initial contents list — every entry must carry
    # ``node_id`` (string) and ``as`` (link|rendered). Unknown ``as``
    # values default to "link" so a malformed entry doesn't crash
    # build but also doesn't accidentally trigger the auto-flip.
    raw_contents = params.get("contents") or []
    if not isinstance(raw_contents, list):
        raw_contents = []
    contents: list[dict] = []
    for entry in raw_contents:
        if not isinstance(entry, dict):
            continue
        node_id = str(entry.get("node_id") or "")
        if not node_id:
            continue
        as_kind = str(entry.get("as") or "link")
        if as_kind not in CHILD_AS_KINDS:
            as_kind = "link"
        child_kind = str(entry.get("child_kind") or "")
        contents.append({"node_id": node_id, "as": as_kind, "child_kind": child_kind})

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "title": str(params.get("title") or "Toolbox"),
        "contents": contents,
        "layer": int(params.get("layer") or 0),
        "displayed_by": str(params.get("displayed_by") or ""),
        "background_color": np.asarray(bg, dtype=np.float32),
        "title_color": np.asarray(title_color, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """A toolbox does not recurse into its children at the engine-emit
    level — the contents are node references (handled by the surface
    + the GUI builder), not engine-spawned subtrees. Phase-2 (rendered
    children) MIGHT recurse; phase-1 renders the title strip + mini-
    icon grid placeholder only."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the title strip + (phase-1 placeholder) child grid.

    Phase-1 expression: title at top + the number of children below.
    Phase-2 (commit 3+) replaces the placeholder with the per-child
    preview-emitter grid per Decision A7.
    """
    screen_w_world = state["screen_width"]
    screen_h_world = state["screen_height"]
    res_max = state["screen_resolution"]

    aspect = screen_w_world / screen_h_world
    if aspect >= 1.0:
        screen_w_px = res_max
        screen_h_px = max(1, int(round(res_max / aspect)))
    else:
        screen_h_px = res_max
        screen_w_px = max(1, int(round(res_max * aspect)))

    internal = _render_toolbox_to_array(
        title=state["title"],
        contents=state["contents"],
        width=screen_w_px,
        height=screen_h_px,
        bg=state["background_color"],
        title_color=state["title_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API.

    Surfaces the title + child count + whether any rendered child is
    present (since that triggers the auto-flip path). The LLM-driver
    uses this to know whether to expect a typed-flip after the next
    add.
    """
    title = state.get("title", "Toolbox")
    contents = state.get("contents", []) or []
    rendered_count = sum(
        1 for c in contents if isinstance(c, dict) and c.get("as") == "rendered"
    )
    link_count = len(contents) - rendered_count
    return (
        f"ToolboxNode id={ctx.node.id} title={title!r} "
        f"contents={len(contents)} (link={link_count}, rendered={rendered_count})"
    )


# ---------------------------------------------------------------------------
# Verb dispatch (idea_queue verb shape)
# ---------------------------------------------------------------------------
#
# All verbs accept payload as a dict and return a state-delta dict
# merged into the per-renderer view-state by ``engine.actions.dispatch_action``.
# Verb-specific delta keys mirror idea_queue's convention:
# ``last_<verb>: {...}`` with success-bool + reason.


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    contents: list[dict] = list(state.get("contents") or [])

    if action_name == "list":
        return {"contents": contents, "last_list": list(contents)}

    if action_name == "add":
        node_id = str(payload.get("node_id") or "").strip()
        as_kind = str(payload.get("as") or "link")
        child_kind = str(payload.get("child_kind") or "")
        if not node_id:
            return {"last_add": {"added": False, "reason": "empty node_id"}}
        if as_kind not in CHILD_AS_KINDS:
            return {"last_add": {
                "added": False, "node_id": node_id,
                "reason": f"unknown as={as_kind!r}; valid: {list(CHILD_AS_KINDS)}",
            }}

        entry = {"node_id": node_id, "as": as_kind, "child_kind": child_kind}
        # Auto-flip trigger — Decision A2: FIRST child with as=rendered.
        # We inspect the EXISTING contents (before append) to decide if
        # this add is the trigger.
        trigger_flip = (
            as_kind == "rendered"
            and not any(c.get("as") == "rendered" for c in contents)
        )
        contents.append(entry)
        state["contents"] = contents  # mutate so subsequent reads see it

        result: Dict[str, Any] = {
            "contents": contents,
            "last_add": {
                "added": True, "node_id": node_id,
                "as": as_kind, "index": len(contents) - 1,
            },
        }
        if trigger_flip:
            typed_kind = _toolbox_inference_rules.infer_typed_kind(child_kind)
            reason = _toolbox_inference_rules.reason_for(child_kind)
            if typed_kind:
                # Surface the auto-flip hint — the substrate side
                # (Alethea-cc) is responsible for the supersession;
                # the runtime side surfaces enough information for any
                # listener (GUI builder, MCP text-API, debug overlay)
                # to know what to publish.
                result["auto_flip"] = {
                    "triggered": True,
                    "first_rendered_child_id": node_id,
                    "first_rendered_child_kind": child_kind,
                    "inferred_typed_kind": typed_kind,
                    "reason": reason or "",
                    "toolbox_id": getattr(node, "id", ""),
                }
            else:
                # Ambiguous-content path — log entry surfaces in the
                # debug overlay (brief 05) so the maintainer can pick a
                # typed-kind manually via the GUI builder.
                result["auto_flip"] = {
                    "triggered": False,
                    "first_rendered_child_id": node_id,
                    "first_rendered_child_kind": child_kind,
                    "reason": "ambiguous toolbox content: no inference rule",
                    "toolbox_id": getattr(node, "id", ""),
                }
        return result

    if action_name == "remove":
        node_id = str(payload.get("node_id") or "").strip()
        if not node_id:
            return {"last_remove": {"removed": False, "reason": "empty node_id"}}
        for i, entry in enumerate(contents):
            if entry.get("node_id") == node_id:
                removed = contents.pop(i)
                state["contents"] = contents
                return {"contents": contents,
                        "last_remove": {"removed": True, "node_id": node_id,
                                         "as": removed.get("as"), "index": i}}
        return {"last_remove": {"removed": False, "node_id": node_id,
                                 "reason": "not in contents"}}

    if action_name in ("up", "down"):
        direction = -1 if action_name == "up" else +1
        try:
            i = int(payload.get("index"))
        except (TypeError, ValueError):
            return {f"last_{action_name}": {
                "moved": False, "reason": "index must be an integer"}}
        j = i + direction
        if not (0 <= i < len(contents)) or not (0 <= j < len(contents)):
            return {f"last_{action_name}": {
                "moved": False, "i": i, "j": j, "len": len(contents),
                "reason": f"out of range: i={i} target={j} len={len(contents)}",
            }}
        contents[i], contents[j] = contents[j], contents[i]
        state["contents"] = contents
        return {"contents": contents,
                f"last_{action_name}": {"moved": True, "i": i, "j": j}}

    if action_name == "move":
        try:
            i = int(payload.get("i"))
            j = int(payload.get("j"))
        except (TypeError, ValueError):
            return {"last_move": {"moved": False,
                                   "reason": "i and j must be integers"}}
        if not (0 <= i < len(contents)) or not (0 <= j < len(contents)):
            return {"last_move": {
                "moved": False, "i": i, "j": j, "len": len(contents),
                "reason": f"out of range: i={i} j={j} len={len(contents)}",
            }}
        contents[i], contents[j] = contents[j], contents[i]
        state["contents"] = contents
        return {"contents": contents,
                "last_move": {"moved": True, "i": i, "j": j}}

    if action_name == "delete":
        try:
            i = int(payload.get("index"))
        except (TypeError, ValueError):
            return {"last_delete": {"deleted": False,
                                     "reason": "index must be an integer"}}
        if not (0 <= i < len(contents)):
            return {"last_delete": {
                "deleted": False, "i": i, "len": len(contents),
                "reason": f"out of range: i={i} len={len(contents)}",
            }}
        removed = contents.pop(i)
        state["contents"] = contents
        return {"contents": contents,
                "last_delete": {"deleted": True, "i": i,
                                  "node_id": removed.get("node_id")}}

    return None


# ---------------------------------------------------------------------------
# Internal: toolbox raster
# ---------------------------------------------------------------------------


def _render_toolbox_to_array(
    title: str,
    contents: list,
    width: int,
    height: int,
    bg: np.ndarray,
    title_color: np.ndarray,
) -> np.ndarray:
    """Render the title strip + child-count placeholder.

    Phase-1 expression — minimal-but-visible. Commit 3+ replaces the
    placeholder with a mini-icon grid via the per-kind preview-emitter
    convention (Decision A7).
    """
    bg_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in bg)
    title_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in title_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)

    font_size = max(12, height // 16)
    font = _get_font(font_size)
    title_font = _get_font(int(font_size * 1.2))

    margin = max(4, font_size // 3)
    line_h = font_size + 4
    y = margin

    if title:
        draw.text((margin, y), title, fill=title_tuple, font=title_font)
        y += int(font_size * 1.6)
        draw.line(
            [(margin, y - 4), (width - margin, y - 4)],
            fill=title_tuple, width=1,
        )

    # Phase-1 placeholder: render a one-line count + the first 5
    # children's node_ids. Commit 3+ replaces with the mini-icon grid.
    if contents:
        summary = f"{len(contents)} item(s)"
        draw.text((margin, y), summary, fill=title_tuple, font=font)
        y += line_h
        for entry in contents[:5]:
            if y + line_h > height - margin:
                break
            node_id = entry.get("node_id", "?")
            as_kind = entry.get("as", "link")
            line = f"  • [{as_kind}] {node_id}"
            draw.text((margin, y), line, fill=title_tuple, font=font)
            y += line_h
        if len(contents) > 5:
            if y + line_h <= height - margin:
                draw.text((margin, y), f"  … +{len(contents) - 5} more",
                          fill=title_tuple, font=font)
    else:
        draw.text((margin, y), "(empty toolbox)",
                  fill=title_tuple, font=font)

    return np.asarray(img, dtype=np.float32) / 255.0
