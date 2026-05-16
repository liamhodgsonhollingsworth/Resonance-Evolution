"""
KeyBindings — a Settings-shaped node holding an input bindings table.

State wraps engine.input.Bindings. The interactive renderer (future)
reads from the active KeyBindings node; multiple KeyBindings can exist
in a scene to express per-mode or per-region control schemes
(e.g. a "vehicle" room overrides movement bindings with steering).

Designed as a node so it inherits the project's general patterns:
hot-reload, save/restore via scene JSON, accessibility profile sharing
via federation. Each binding is a (pattern, action_name) pair; pattern
matches happen in the input system.

v1 ships the Minecraft default bindings as a starting point; the user's
"Mouse and controller sensitivity for looking around uses the same scale"
intention is captured in the look_sensitivity field which is shared
across mouse and controller (controller support is future work and reads
from the same field).

No visual emit. describe() surfaces the table.
"""

from __future__ import annotations

import numpy as np

from engine.input import Bindings
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="KeyBindings",
        version="1.0",
        renderer_id="raster",
        inputs={"profile": "str", "move_speed": "float",
                "look_sensitivity": "float", "scroll_zoom_factor": "float",
                "double_tap_window": "float", "overrides": "dict"},
        outputs={},
        description=(
            "Bindable control scheme. Wraps engine.input.Bindings. The "
            "interactive renderer reads from the active KeyBindings."
        ),
    )


def build(params):
    profile = str(params.get("profile", "minecraft"))
    bindings = Bindings.default() if profile == "minecraft" else Bindings()
    bindings.move_speed = float(params.get("move_speed", bindings.move_speed))
    bindings.look_sensitivity = float(params.get("look_sensitivity", bindings.look_sensitivity))
    bindings.scroll_zoom_factor = float(params.get("scroll_zoom_factor", bindings.scroll_zoom_factor))
    bindings.double_tap_window = float(params.get("double_tap_window", bindings.double_tap_window))
    return {
        "profile": profile,
        "bindings": bindings,
        "overrides": dict(params.get("overrides", {})),
    }


def precompute_hook(state, engine, node):
    """Register as the active bindings if no other has."""
    engine.cache.setdefault("__active_key_bindings__", node.id)
    return {"profile": state["profile"]}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    b = state["bindings"]
    return (f"KeyBindings id={ctx.node.id} profile={state['profile']} "
            f"move_speed={b.move_speed} look_sensitivity={b.look_sensitivity} "
            f"entries={len(b.table)}")
