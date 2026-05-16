"""
Apeiron engine — public API.

The engine loads node-type modules from node_types/ and renderers/, spawns
node instances, walks the graph from a viewer, and assembles channel output
(color, depth, optional normal, optional ID — extensible by name).

See architecture.md for the load-bearing design commitments. The short
version: every node implements emit(state, view, context) returning a
channel dict; the engine wraps every call in try/except for module
isolation; topology lives on connections rather than coordinates;
recursion depth IS the LOD mechanism.
"""

from engine.node import Manifest, NodeInstance, View, Channels, EmitContext, look_at
from engine.core import Engine
from engine.bundle import write_bundle

__all__ = [
    "Engine",
    "Manifest",
    "NodeInstance",
    "View",
    "Channels",
    "EmitContext",
    "look_at",
    "write_bundle",
]
