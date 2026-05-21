"""IdeaQueue — file-backed ordered list of ideas.

Lift #7 of the chat_router architectural arc. Before this node, idea
queue file CRUD lived in ``tools/workflow_streamlit/commands.py`` as
inline business logic (~90 LOC of file I/O + list manipulation).
Lifting it gives the same operations to the Tk surface, the HTML/MCP
callers, and any future surface — and decouples the file format from
the call sites.

Verbs:
  - ``list``   — return current items (loads from disk on each call)
  - ``add``    — append text; persist
  - ``up``     — swap with previous index; persist
  - ``down``   — swap with next index; persist
  - ``delete`` — remove at index; persist
  - ``move``   — swap items at i and j (used by up/down internally)

File format (``state_dir/idea_queue.md``):

    # Idea queue

    - first item
    - second item
    - third item

Empty queue is written as ``# Idea queue\n\n`` (no items, no trailing
newline beyond the header). The node reads ``state_dir`` from
``engine.cache["__workflow__"]["state_dir"]``; tests register a
tmp_path-based state_dir in the fixture.

The node mirrors the maintainer's *"separate as many nodes as possible
into composite nodes that are all linked together"* directive: a
surface that wants to ALSO mirror ideas into a chat session (e.g.
"idea-queue.broadcast") composes idea_queue.list + session_sender.send
via the same dispatch pattern chat_router already uses.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="IdeaQueue",
        version="1.0",
        renderer_id="logic",
        inputs={"filename": "string"},
        outputs={},
        description=(
            "File-backed ordered list of idea queue items. Verbs: "
            "list/add/up/down/delete. Reads state_dir from the "
            "workflow singleton."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {"filename": params.get("filename") or "idea_queue.md"}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"IdeaQueue id={ctx.node.id} file={state.get('filename')!r}"


def _state_dir(engine: Any) -> Optional[Path]:
    """Pull state_dir off the workflow singleton.

    Returns None when no singleton is registered (i.e. an engine
    booted outside the Streamlit runtime); callers downgrade to an
    error result so the headless test path can still exercise the
    node in isolation if it pre-registers state_dir itself.
    """
    workflow = engine.cache.get("__workflow__") or {}
    sd = workflow.get("state_dir")
    return Path(sd) if sd is not None else None


def _file_path(state: Dict[str, Any], engine: Any) -> Optional[Path]:
    sd = _state_dir(engine)
    if sd is None:
        return None
    return sd / state.get("filename", "idea_queue.md")


def _load(path: Path) -> List[str]:
    if not path.exists():
        return []
    out: List[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("- "):
            out.append(line[2:].strip())
    return out


def _save(path: Path, items: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = (
        "# Idea queue\n\n"
        + "\n".join(f"- {it}" for it in items)
        + ("\n" if items else "")
    )
    path.write_text(body, encoding="utf-8")


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    path = _file_path(state, engine)
    if path is None:
        # No state_dir registered; surface a clean error so the
        # surface can show a "configure state_dir" hint rather than
        # crash.
        return {"last_error": "no state_dir on workflow singleton"}

    if action_name == "list":
        items = _load(path)
        return {"items": items, "last_list": items}

    if action_name == "add":
        text = (payload.get("text") or "").strip()
        if not text:
            return {"last_add": {"added": False, "reason": "empty text"}}
        items = _load(path)
        items.append(text)
        _save(path, items)
        return {"items": items,
                "last_add": {"added": True, "index": len(items) - 1, "text": text}}

    if action_name in ("up", "down"):
        direction = -1 if action_name == "up" else +1
        try:
            i = int(payload.get("index"))
        except (TypeError, ValueError):
            return {f"last_{action_name}": {"moved": False,
                                            "reason": "index must be an integer"}}
        items = _load(path)
        j = i + direction
        if not (0 <= i < len(items)) or not (0 <= j < len(items)):
            return {f"last_{action_name}": {
                "moved": False, "i": i, "j": j, "len": len(items),
                "reason": f"out of range: i={i} target={j} len={len(items)}",
            }}
        items[i], items[j] = items[j], items[i]
        _save(path, items)
        return {"items": items,
                f"last_{action_name}": {"moved": True, "i": i, "j": j}}

    if action_name == "move":
        try:
            i = int(payload.get("i"))
            j = int(payload.get("j"))
        except (TypeError, ValueError):
            return {"last_move": {"moved": False,
                                   "reason": "i and j must be integers"}}
        items = _load(path)
        if not (0 <= i < len(items)) or not (0 <= j < len(items)):
            return {"last_move": {
                "moved": False, "i": i, "j": j, "len": len(items),
                "reason": f"out of range: i={i} j={j} len={len(items)}",
            }}
        items[i], items[j] = items[j], items[i]
        _save(path, items)
        return {"items": items,
                "last_move": {"moved": True, "i": i, "j": j}}

    if action_name == "delete":
        try:
            i = int(payload.get("index"))
        except (TypeError, ValueError):
            return {"last_delete": {"deleted": False,
                                     "reason": "index must be an integer"}}
        items = _load(path)
        if not (0 <= i < len(items)):
            return {"last_delete": {
                "deleted": False, "i": i, "len": len(items),
                "reason": f"out of range: i={i} len={len(items)}",
            }}
        removed = items.pop(i)
        _save(path, items)
        return {"items": items,
                "last_delete": {"deleted": True, "i": i, "text": removed}}

    return None
