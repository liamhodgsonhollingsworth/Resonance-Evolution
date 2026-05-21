"""SceneLoader — list/load/current scene operations.

Verbs:
  - ``list``    — list ``*.json`` files in the apeiron_root/scenes/ directory.
                  Result via view-state ``scenes: list[str]``.
  - ``load``    — load a named scene; supports bare name or ``<name>.json``.
                  Calls engine.load_scene + engine.precompute. Result via
                  view-state ``last_load: {loaded, scene, reason}``.
  - ``current`` — return the currently-loaded scene name from view-state.
  - ``reload``  — re-load the currently-loaded scene from disk; closes the
                  scenes-JSON-not-watched gap surfaced in the 2026-05-21
                  bare-minimum audit. Falls back to the runtime's
                  ``default_scene`` when no current scene is recorded.

Lifts the inline scene-management logic from
``tools/workflow_streamlit/commands.py::_scene_*``. Same primitive
available to the Tk surface, the text-API, and any future MCP-tool
caller without each reimplementing the file-glob + load + precompute
sequence.

apeiron_root comes from ``engine.cache['__workflow__']['apeiron_root']``
(registered alongside session_manager + inbox at boot). If the workflow
context isn't registered, ``list`` and ``load`` soft-fail with a clear
reason rather than crashing.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SceneLoader",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Lists, loads, and reports the currently-loaded scene. "
            "Wraps engine.load_scene + engine.precompute so any "
            "surface or MCP-tool caller dispatches a single action."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"SceneLoader id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    workflow = engine.cache.get("__workflow__") or {}
    apeiron_root = workflow.get("apeiron_root")

    if action_name == "list":
        if not apeiron_root:
            return {"scenes": [], "error": "no apeiron_root in __workflow__"}
        scenes_dir = Path(apeiron_root) / "scenes"
        if not scenes_dir.exists():
            return {"scenes": [], "error": "no scenes/ directory"}
        names = sorted(p.name for p in scenes_dir.glob("*.json"))
        return {"scenes": names, "error": None}

    if action_name == "load":
        if not apeiron_root:
            return {"last_load": {
                "loaded": False, "scene": None,
                "reason": "no apeiron_root in __workflow__",
            }}
        name = (payload.get("name") or "").strip()
        if not name:
            return {"last_load": {
                "loaded": False, "scene": None, "reason": "empty name",
            }}
        scenes_dir = Path(apeiron_root) / "scenes"
        target = scenes_dir / (name if name.endswith(".json") else f"{name}.json")
        if not target.exists():
            return {"last_load": {
                "loaded": False, "scene": target.name,
                "reason": f"scene not found: {target.name}",
            }}
        try:
            engine.load_scene(target)
            engine.precompute()
        except Exception as exc:
            return {"last_load": {
                "loaded": False, "scene": target.name,
                "reason": f"load failed: {exc}",
            }}
        return {"last_load": {
            "loaded": True, "scene": target.name,
            "reason": f"loaded {target.name}",
        }, "current_scene": target.name}

    if action_name == "current":
        view = engine.cache.setdefault("__view_state__", {}).setdefault(node.id, {})
        current = view.get("current_scene")
        return {"last_current": current}

    if action_name == "reload":
        if not apeiron_root:
            return {"last_reload": {
                "reloaded": False, "scene": None,
                "reason": "no apeiron_root in __workflow__",
            }}
        view = engine.cache.setdefault("__view_state__", {}).setdefault(node.id, {})
        # Prefer the explicit currently-loaded scene; fall back to the
        # workflow-singleton's default_scene if set; final fallback is
        # workflow_view.json (the canonical default scene name).
        name = (
            payload.get("name")
            or view.get("current_scene")
            or workflow.get("default_scene")
            or "workflow_view.json"
        )
        scenes_dir = Path(apeiron_root) / "scenes"
        target = scenes_dir / (
            name if str(name).endswith(".json") else f"{name}.json"
        )
        if not target.exists():
            return {"last_reload": {
                "reloaded": False, "scene": target.name,
                "reason": f"scene not found: {target.name}",
            }}
        try:
            engine.load_scene(target)
            engine.precompute()
        except Exception as exc:
            return {"last_reload": {
                "reloaded": False, "scene": target.name,
                "reason": f"reload failed: {exc}",
            }}
        return {
            "last_reload": {
                "reloaded": True, "scene": target.name,
                "reason": f"reloaded {target.name}",
            },
            "current_scene": target.name,
        }

    return None
