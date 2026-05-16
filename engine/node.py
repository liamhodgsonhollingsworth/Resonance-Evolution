"""
The node primitive. Every node-type module exposes:

    def manifest() -> Manifest: ...
    def build(params: dict) -> Any: ...                    # optional, defaults to params
    def emit(state, view, ctx: EmitContext) -> Channels: ...
    def describe(state, ctx: EmitContext) -> str: ...      # optional, for text rendering
    def step(state, dt, neighbors) -> Any: ...             # optional, for animation

The engine reads manifest() to register the type without loading the rest
of the module; calls build() once at spawn time; calls emit() per frame.
"""

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple, TYPE_CHECKING
import numpy as np

if TYPE_CHECKING:
    from engine.core import Engine


# ---------------------------------------------------------------------------
# Channels: the wire payload between nodes.
#
# Values are typically np.ndarray (color, depth, normal, ids) but may also
# be strings (text) or arbitrary objects (BehaviorSummary, etc.). New
# channel names never break existing consumers — readers pick what they
# know about and ignore the rest. From the prior-art synthesis: every
# system that fixed its wire shape early paid for it later.
# ---------------------------------------------------------------------------
Channels = Dict[str, Any]


@dataclass
class Manifest:
    """
    Typed contract for a node-type module. Adding fields is non-breaking —
    old consumers ignore unknown fields. Renaming or removing a field is a
    breaking change; bump `version` and add migrators.
    """
    name: str
    version: str = "1.0"
    renderer_id: str = "raster"
    inputs: Dict[str, str] = field(default_factory=dict)
    outputs: Dict[str, str] = field(default_factory=dict)
    description: str = ""


@dataclass
class NodeInstance:
    """
    A live instance of a node-type in a scene graph.

    Connections carry an optional 4x4 transform applied when traversing —
    this is the topology-over-coordinates primitive. Euclidean space is
    the case where all connection-transforms compose to identity around
    cycles; non-Euclidean / portal / wrapping geometries are the case
    where they don't. Equal handling either way.
    """
    id: str
    type_name: str
    params: Dict[str, Any] = field(default_factory=dict)
    state: Any = None
    connections: Dict[str, Any] = field(default_factory=dict)
    dead: bool = False
    error: str = ""


@dataclass
class View:
    """
    Viewer state passed to emit(). Position and orientation are in the
    current node's local frame; scale is the LOD/zoom parameter — nodes
    use it to decide whether to render themselves or recurse to children.
    Width and height are the target render resolution.
    """
    position: np.ndarray = field(default_factory=lambda: np.array([0.0, 0.0, 5.0]))
    orientation: np.ndarray = field(default_factory=lambda: np.eye(3))
    scale: float = 1.0
    width: int = 256
    height: int = 256
    fov_y_radians: float = np.pi / 4  # 45 degrees default

    def aspect(self) -> float:
        return self.width / self.height


@dataclass
class EmitContext:
    """
    Context passed to emit(). Gives a node access to the engine (for
    reading sibling state, dispatching to renderers, walking children
    directly when needed) plus its own NodeInstance and precomputed
    children's outputs.

    Adding fields is non-breaking — old emit() implementations that
    don't use them continue to work.
    """
    engine: "Engine"
    node: NodeInstance
    child_outputs: Dict[str, Tuple[NodeInstance, Channels]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def look_at(eye, target, up=(0.0, 1.0, 0.0)) -> np.ndarray:
    """
    Build a 3x3 orientation matrix such that view.orientation @ [0,0,-1]
    in camera space lands on the world-space forward direction (target - eye).
    Columns are [right, up, -forward].
    """
    eye = np.asarray(eye, dtype=np.float64)
    target = np.asarray(target, dtype=np.float64)
    up = np.asarray(up, dtype=np.float64)
    forward = target - eye
    n = np.linalg.norm(forward)
    if n < 1e-9:
        return np.eye(3)
    forward = forward / n
    right = np.cross(forward, up)
    rn = np.linalg.norm(right)
    if rn < 1e-9:
        # eye/target colinear with up; pick an arbitrary right
        right = np.cross(forward, np.array([1.0, 0.0, 0.0]))
        rn = np.linalg.norm(right)
        if rn < 1e-9:
            right = np.cross(forward, np.array([0.0, 0.0, 1.0]))
            rn = np.linalg.norm(right)
    right = right / rn
    up_corrected = np.cross(right, forward)
    return np.stack([right, up_corrected, -forward], axis=1)
