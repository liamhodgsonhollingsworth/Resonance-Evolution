"""
Seed — a parameter holder for procedural generation.

State is a dict of named parameters plus an integer `rng_seed`. The seed
itself does not render — it is consumed by a Generator (via a connection)
that produces content from these parameters.

The Seed's parameters are the "dials" the user can tune. A Generator's
inverse pass (invert_hook) computes which parameter to adjust when the
user edits a generated piece of content; the Seed receives the parameter
delta and the affected sub-graph re-precomputes.

This is a data-only node: emit returns empty image channels so that the
node renders as a no-op when included in a visual scene; describe() is
used for the text-renderer.
"""

from __future__ import annotations

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Seed",
        version="1.0",
        renderer_id="raster",
        inputs={"rng_seed": "int", "params": "dict"},
        outputs={},
        description=(
            "Parameter holder for procedural generation. Consumed by a "
            "Generator via the 'seed' connection. No visual emit; the "
            "Generator (or any other consumer) reads state directly."
        ),
    )


def build(params):
    return {
        "rng_seed": int(params.get("rng_seed", 0)),
        "params": dict(params.get("params", {})),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    w, h = view.width, view.height
    return {
        "color": np.zeros((h, w, 3), dtype=np.float32),
        "depth": np.full((h, w), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    keys = sorted(state["params"].keys())
    return (f"Seed id={ctx.node.id} rng_seed={state['rng_seed']} "
            f"params={{{', '.join(keys)}}}")
