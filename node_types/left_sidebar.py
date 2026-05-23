"""LeftSidebarNode — vertical bar variant of BarNode anchored to the
left.

Brief 04 commit 2 of the Resonance website implementation arc. Per
SPEC-112 + Decision A5: the vertical-bar variants (Left / Right) have
default geometry biased toward tall-narrow rectangles, with
`orientation: vertical` + the per-variant anchor default. See
``node_types/bar.py`` for the design + composition contract.
"""

from __future__ import annotations

from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View

from node_types import bar as _bar_module


def manifest() -> Manifest:
    return _bar_module._make_manifest("LeftSidebarNode")


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return _bar_module._build_with_kind("LeftSidebarNode", params)


def select_children(state, view: View, engine, node) -> List[str]:
    return _bar_module.select_children(state, view, engine, node)


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return _bar_module.emit(state, view, ctx)


def describe(state, ctx: EmitContext) -> str:
    return _bar_module.describe(state, ctx)


is_locked = _bar_module.is_locked
