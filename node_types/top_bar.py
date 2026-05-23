"""TopBarNode — horizontal bar variant of BarNode anchored to the top.

Brief 04 commit 2 of the Resonance website implementation arc. Per
SPEC-112 + the per-module plan's Decision A5, TopBarNode is one of
four BarNode variants (Top / Bottom / Left / Right) shipped together;
each is a distinct kind so the interaction-rule infrastructure can
match on it directly (e.g. `interaction-rule:top-bar-onto-rectangle`)
and the attachment's anchor field defaults sensibly from the kind
alone.

The variant carries `orientation: horizontal` + `anchor_default: top`
as documented defaults. Composition delegates to ``node_types/bar.py``
for the manifest + build + emit pipeline.

See ``node_types/bar.py`` for the design rationale + composition
contract.
"""

from __future__ import annotations

from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View

from node_types import bar as _bar_module


def manifest() -> Manifest:
    return _bar_module._make_manifest("TopBarNode")


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return _bar_module._build_with_kind("TopBarNode", params)


def select_children(state, view: View, engine, node) -> List[str]:
    return _bar_module.select_children(state, view, engine, node)


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return _bar_module.emit(state, view, ctx)


def describe(state, ctx: EmitContext) -> str:
    return _bar_module.describe(state, ctx)


is_locked = _bar_module.is_locked
