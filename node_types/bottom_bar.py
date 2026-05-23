"""BottomBarNode — horizontal bar variant of BarNode anchored to the
bottom.

Brief 04 commit 2 of the Resonance website implementation arc. Sister
variant to TopBarNode; same shape, different default anchor. See
``node_types/bar.py`` + ``node_types/top_bar.py`` for the design + the
composition contract.
"""

from __future__ import annotations

from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View

from node_types import bar as _bar_module


def manifest() -> Manifest:
    return _bar_module._make_manifest("BottomBarNode")


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return _bar_module._build_with_kind("BottomBarNode", params)


def select_children(state, view: View, engine, node) -> List[str]:
    return _bar_module.select_children(state, view, engine, node)


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return _bar_module.emit(state, view, ctx)


def describe(state, ctx: EmitContext) -> str:
    return _bar_module.describe(state, ctx)


is_locked = _bar_module.is_locked
