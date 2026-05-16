"""
PainterlyPostProcessor — a renderer-node that consumes the bundle channels
produced by its "source" sub-graph and applies painterly effects: color
quantization (palette reduction) plus ID-edge darkening (object outlines).
Returns the modified channels.

Demonstrates the bundle-format-as-pipeline-seam in working code — this
renderer doesn't render geometry directly, it post-processes another
sub-graph's channels. Validates that bundles ARE a clean pipeline seam
by serving as both an export format AND an internal compositing
contract.

v1 has two effects baked in (quantization + edges); v2 can factor each
into its own renderer-node and chain them via composition. The interface
(source connection, emit returning modified channels) stays identical.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="PainterlyPostProcessor",
        version="1.0",
        renderer_id="raster",
        inputs={
            "quantization_levels": "int",
            "edge_darkening": "float",
        },
        outputs={"color": "rgb_image", "depth": "depth_image", "ids": "id_image"},
        description=(
            "Consumes a 'source' sub-graph's bundle channels (color + ids); "
            "applies palette-reduction and ID-edge darkening; returns the "
            "modified channels. The first bundle-consuming renderer; "
            "validates the bundle format as a pipeline seam."
        ),
    )


def build(params):
    return {
        "quantization_levels": int(params.get("quantization_levels", 6)),
        "edge_darkening": float(params.get("edge_darkening", 0.35)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    source = ctx.child_outputs.get("source")
    if source is None:
        return _empty_channels(view)
    _, channels = source
    color = channels.get("color")
    if color is None:
        return channels

    out_color = np.array(color, dtype=np.float32, copy=True)

    levels = state["quantization_levels"]
    if levels > 0:
        out_color = np.round(out_color * levels) / float(levels)
        out_color = np.clip(out_color, 0.0, 1.0)

    ids = channels.get("ids")
    if ids is not None:
        ids_arr = np.asarray(ids)
        edge_x = ids_arr != np.roll(ids_arr, 1, axis=1)
        edge_y = ids_arr != np.roll(ids_arr, 1, axis=0)
        edges = edge_x | edge_y
        # Drop the wrap-around at the image borders so they don't render as edges
        edges[:, 0] = False
        edges[0, :] = False
        darkening = state["edge_darkening"]
        out_color = np.where(edges[..., None], out_color * darkening, out_color)
        out_color = np.clip(out_color, 0.0, 1.0)

    result = dict(channels)
    result["color"] = out_color.astype(np.float32)
    return result


def describe(state, ctx: EmitContext) -> str:
    return (f"PainterlyPostProcessor id={ctx.node.id} "
            f"levels={state['quantization_levels']} "
            f"edge_darken={state['edge_darkening']:.2f}")


def _empty_channels(view: View) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }
