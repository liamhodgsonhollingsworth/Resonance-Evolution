"""
SimulationProbe — pre-simulate node interactions before runtime.

Companion to the Aggregator: where Aggregator precomputes a coarse-scale
visual impostor, SimulationProbe precomputes a *behavior trajectory* over
a time horizon. State carries:
- horizon: number of time steps to simulate
- dt: step size in world time
- observed: list of node ids to observe (None means "all observable
  connected children")

At sim_precompute_hook time, the probe calls each observed node's
step(state, dt, neighbors) function `horizon` times, building a per-node
trajectory (list of states keyed by step index). The trajectory is
stored in engine.cache[node_id + "__sim__"] — separate cache slot from
regular precompute so a node can carry both an impostor and a
simulation trajectory.

emit() exposes the trajectory on a `simulation` channel for renderers
that consume it (predicted-path overlays, equilibrium markers — not yet
built). The default compositor ignores unknown channels, so this node
doesn't disturb existing visual renders.

This is the architectural footprint of the user's "Any arbitrary
interaction is pre-simulated... emergent behavior beforehand for any
arbitrary interaction" requirement. New interaction types are new
node-types implementing step(); the probe picks them up via the same
hook discovery the engine already uses for precompute and select_children.
"""

from __future__ import annotations

from typing import Any, Dict, List

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SimulationProbe",
        version="1.0",
        renderer_id="raster",
        inputs={"horizon": "int", "dt": "float", "observed": "list[str]"},
        outputs={"simulation": "trajectory"},
        description=(
            "Pre-simulates step() interactions over a horizon at "
            "sim_precompute time. Stores trajectories in "
            "cache[node_id + '__sim__']."
        ),
    )


def build(params):
    return {
        "horizon": int(params.get("horizon", 32)),
        "dt": float(params.get("dt", 0.05)),
        "observed": list(params.get("observed", [])),
    }


def sim_precompute_hook(state, engine, node):
    """
    Run `horizon` ticks; record each observed node's state per step.

    A node-type module implements step() to participate; nodes whose
    modules don't expose step() are skipped (their trajectory is just
    a sequence of identical state values, which is also a valid
    no-op trajectory).
    """
    targets = list(state["observed"])
    if not targets:
        # Default: all directly-connected children.
        targets = list(node.connections.values())
        targets = [t if isinstance(t, str) else
                   (t.get("target") if isinstance(t, dict) else (t[0] if isinstance(t, list) and t else None))
                   for t in targets]
        targets = [t for t in targets if t and t in engine.nodes]

    trajectories: Dict[str, List[Any]] = {t: [] for t in targets}
    horizon = state["horizon"]
    dt = state["dt"]
    for step in range(horizon):
        for t in targets:
            target = engine.nodes.get(t)
            if target is None or target.dead:
                trajectories[t].append(None)
                continue
            module = engine.types.get(target.type_name)
            if module is None or not hasattr(module, "step"):
                # No step() — trajectory keeps the current state snapshot.
                trajectories[t].append(_snapshot(target.state))
                continue
            try:
                neighbors = _neighbor_states(engine, target)
                target.state = module.step(target.state, dt, neighbors)
                trajectories[t].append(_snapshot(target.state))
            except Exception as e:
                engine.errors.append(f"step({t}): {e}")
                trajectories[t].append(None)

    return {"horizon": horizon, "dt": dt, "trajectories": trajectories}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """No visual contribution by default; expose the trajectory on a
    named channel for future trajectory-rendering nodes."""
    traj = ctx.engine.cache.get(ctx.node.id + "__sim__", {})
    out = {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }
    if traj:
        out["simulation"] = traj
    return out


def describe(state, ctx: EmitContext) -> str:
    return (f"SimulationProbe id={ctx.node.id} horizon={state['horizon']} "
            f"dt={state['dt']} observing={len(state['observed'])}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _snapshot(state):
    """Best-effort copy of a node's state. Dicts are shallow-copied; other
    types are returned by reference. Future: deepcopy when the simulation
    needs full history isolation."""
    if isinstance(state, dict):
        return dict(state)
    return state


def _neighbor_states(engine, node):
    """For the step() call, hand the node references to its connected
    neighbors' states. step() implementations may mutate based on those."""
    neighbors = {}
    for name, conn in node.connections.items():
        if isinstance(conn, str):
            tid = conn
        elif isinstance(conn, dict):
            tid = conn.get("target")
        elif isinstance(conn, list) and conn:
            tid = conn[0]
        else:
            continue
        neighbor = engine.nodes.get(tid)
        if neighbor is not None and not neighbor.dead:
            neighbors[name] = neighbor.state
    return neighbors
