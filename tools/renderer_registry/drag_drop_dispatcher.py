"""Drag-and-drop dispatcher — production runtime wired through the registry.

Schema-version: 2
Filed: 2026-05-29 per MVP plan Wave 2 (Subagent W2-A).
Authored by: session jovial-margulis-52985e in worktree
             C:/Users/Liam/Desktop/Alethea/.claude/worktrees/jovial-margulis-52985e/

This is the production lift of the Wave 1 baseline at
`tools/weavemind_eval/drag_drop_dispatcher_baseline.py`. Same five-phase shape;
the canonical specification still lives at `drag_drop_dispatcher.weft`. The
upgrade: accepts events for every kind in the renderer registry (not just the
12-case adversarial slice), composes with the registry for dispatch lookup,
and emits structured graph-mutation events ready for the MCP write path.

Hybrid posture per skills/weavemind-first.md Exception case 5 (Weft batch CLI
not available). The .weft file is the source-of-truth spec; this module is the
runtime; both share the same dispatch table + tier-window rule + modifier
overrides. When Weft batch-mode ships, this module collapses to a thin loader.

Algorithm (matches the .weft program's five phases):
    Phase 1 — guard      : self-drop, null-target, tier-window, kind-registry
    Phase 2 — classify   : dispatch (source_kind, target_kind, modifiers)
    Phase 3 — emit       : ConnectionEdit (add/replace based on existing pair)
    Phase 4 — project    : next graph state (pure functional)
    Phase 5 — rejection  : tooltip text for UI's right-click menu

Wave 2 deltas vs. the Wave 1 baseline:
    1. Kind validation reads through `tools.renderer_registry.registry`
       rather than a hardcoded `RENDERER_KINDS` set. Adding a kind to the
       registry makes it droppable; no dispatcher edit required.
    2. The dispatcher exposes a `GraphMutationEvent` shape downstream
       consumers (MCP write path, render-tick pipeline, undo stack) read.
    3. Connection-relations are also a registry-driven allowlist — the
       same single-source-of-truth pattern.
    4. The harness supports streamed input (JSONL) for the FastAPI sidecar.

Invocation:
    from tools.renderer_registry.drag_drop_dispatcher import dispatch
    result = dispatch(event, graph)        # -> DispatchResult

CLI:
    python -m tools.renderer_registry.drag_drop_dispatcher --test
    python -m tools.renderer_registry.drag_drop_dispatcher --bench
    python -m tools.renderer_registry.drag_drop_dispatcher --serve  # stdin JSONL
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import json
import logging
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

# Import the registry as the dispatcher's kind-validation source of truth.
# Sys-path tweak: when invoked as a module via `python -m`, the parent
# import works; when invoked directly, fall back to relative-path discovery.
try:
    from tools.renderer_registry.registry import (
        RendererRegistry,
        get_registry,
    )
except ImportError:
    _here = Path(__file__).resolve().parent
    sys.path.insert(0, str(_here.parents[1]))  # apeiron root
    from tools.renderer_registry.registry import (  # noqa: E402
        RendererRegistry,
        get_registry,
    )


# ============================================================================
# Type model — same shape as the .weft port types
# ============================================================================


class WorldlineTier(enum.IntEnum):
    """Ordered tiers; ordering drives the tier-window check."""

    sci_fi = 0
    planned = 1
    in_progress = 2
    realized = 3
    maintained = 4

    @classmethod
    def parse(cls, value: str | None) -> "WorldlineTier | None":
        if value is None:
            return None
        normalized = str(value).replace("-", "_").lower()
        return cls[normalized] if normalized in cls.__members__ else None


# The substrate's canonical connection-relation vocabulary. The dispatcher
# validates relations against this set; the relation-vocabulary surface
# (SPEC-096 + SPEC-097) layers atop this same set.
CONNECTION_RELATIONS: frozenset[str] = frozenset([
    "depends-on", "composes-with", "realizes", "implements", "displays",
    "references", "crystallizes-to", "superseded-by", "instantiates",
    "spawns", "displayed_by", "displayed-by",
])


@dataclass(frozen=True)
class Point:
    x: float
    y: float


@dataclass(frozen=True)
class DragEvent:
    """The drag event the website UI emits — exact wave-1 shape."""

    source_id: str
    source_kind: str
    source_tier: WorldlineTier | None
    target_id: str | None
    target_kind: str | None
    target_tier: WorldlineTier | None
    modifier_keys: tuple[str, ...] = ()
    pointer_position: Point = field(default_factory=lambda: Point(0.0, 0.0))


@dataclass(frozen=True)
class Edge:
    source: str
    relation: str
    target: str


@dataclass
class GraphState:
    """Current renderer + connection state."""

    nodes: dict[str, dict[str, Any]] = field(default_factory=dict)
    connections: list[Edge] = field(default_factory=list)
    tier_map: dict[str, WorldlineTier] = field(default_factory=dict)


@dataclass(frozen=True)
class ConnectionEdit:
    """The edit payload the MCP write path consumes."""

    operation: str  # "add" | "remove" | "replace"
    source: str
    relation: str
    target: str
    confidence: float
    provenance: str


@dataclass(frozen=True)
class RejectionReason:
    kind: str
    detail: str


@dataclass(frozen=True)
class GraphMutationEvent:
    """The structured event downstream consumers (MCP write, undo-stack, render
    pipeline) subscribe to. New in Wave 2 — names the *event* shape rather than
    only the *edit* shape, so emit-time hooks (audit, telemetry) can hang off
    a single signal.
    """

    event_type: str  # "connection_add" | "connection_replace" | "connection_remove" | "rejected"
    edit: ConnectionEdit | None
    rejection: RejectionReason | None
    emitted_at: float
    source_tick: str  # opaque ID per dispatch tick (for batched undo)


@dataclass(frozen=True)
class DispatchResult:
    """The dispatcher's output ports — what the renderer-tick consumes."""

    edit: ConnectionEdit | None
    next_state: GraphState
    rejection: str | None  # human-readable tooltip, for the right-click menu
    mutation_event: GraphMutationEvent


# ============================================================================
# Dispatch table — mirrors the .weft Phase 2 config block.
#
# Adding a new (source_kind, target_kind) pair = one row here AND one row
# in `renderer_registry.weft` Phase 2's `kinds:` block. Per Sophia's review,
# the single-source-of-truth is the registry — the dispatcher reads kinds
# from the registry but the relation-mapping is the dispatcher's data.
# ============================================================================

DISPATCH_TABLE: dict[tuple[str, str], str] = {
    # tasks <-> calendar / tasks
    ("tasks-list-item", "calendar-entry"): "realizes",
    ("tasks-list-item", "tasks-list-item"): "depends-on",
    ("tasks-list-item", "tasks-list"): "composes-with",

    # chat <-> ideas
    ("chat-bubble", "idea-card"): "references",
    ("chat-thread", "chat-bubble"): "displays",

    # ideas <-> ideas / planned
    ("idea-card", "idea-card"): "composes-with",
    ("idea-card", "planned-node"): "crystallizes-to",
    ("sci-fi-node", "planned-node"): "crystallizes-to",

    # 3D pipeline
    ("3d-canvas", "camera"): "composes-with",
    ("3d-canvas", "render-bundle"): "spawns",
    ("render-bundle", "painterly-output"): "displayed_by",
    ("camera", "viewer-state"): "composes-with",

    # window-manager + paste-target + generic renderer
    ("paste-target", "renderer-node"): "instantiates",
    ("palette-item", "workspace"): "spawns",
    ("panel", "window"): "displays",
    ("window", "panel"): "composes-with",
}


MODIFIER_OVERRIDES: dict[str, str] = {
    "ctrl": "references",
    "shift": "composes-with",
    "alt": "depends-on",
}


# Tier-window: a node can only connect to nodes within +/- this many tiers.
# Sci-fi (0) -> in-progress (2) = OK (distance 2). Sci-fi -> maintained (4) = NOT OK.
TIER_WINDOW = 2


# Confidence levels — mirrors the .weft program's grading.
CONF_MODIFIER = 0.95     # explicit modifier-override
CONF_DISPATCH = 0.85     # dispatch-table hit
CONF_FALLBACK = 0.3      # fallback to "references"


# ============================================================================
# Phase 1 — guard (kind validation now reads the registry)
# ============================================================================


def guard(
    event: DragEvent,
    graph: GraphState,
    registry: RendererRegistry | None = None,
) -> tuple[DragEvent | None, RejectionReason | None]:
    """Validate the drag event. Returns (valid_event, rejection) — one is None.

    Wave-2 change: kind validation reads the registry rather than a local
    constant. Any kind registered (Apeiron-native OR MVP-virtual) is
    droppable; unregistered kinds are rejected as `invalid_kind`.
    """
    if registry is None:
        registry = get_registry()

    # Rule 1 — self-drop
    if event.source_id == event.target_id:
        return None, RejectionReason("self_drop", "cannot drop a node on itself")

    # Rule 2 — null target
    if event.target_id is None or event.target_kind is None:
        return None, RejectionReason(
            "null_target", "drop on empty canvas is layout-only, not a connection"
        )

    # Rule 3 — kind registry validation (reads through the registry)
    if not registry.is_registered(event.source_kind):
        return None, RejectionReason(
            "invalid_kind", f"source kind {event.source_kind!r} not in registry"
        )
    if not registry.is_registered(event.target_kind):
        return None, RejectionReason(
            "invalid_kind", f"target kind {event.target_kind!r} not in registry"
        )

    # Rule 4 — tier-window check
    if event.source_tier is not None and event.target_tier is not None:
        tier_distance = abs(int(event.source_tier) - int(event.target_tier))
        if tier_distance > TIER_WINDOW:
            return None, RejectionReason(
                "invalid_tier",
                f"tier distance {tier_distance} > window {TIER_WINDOW} "
                f"({event.source_tier.name} -> {event.target_tier.name})",
            )

    return event, None


# ============================================================================
# Phase 2 — classify (modifier overrides win; then dispatch table; then fallback)
# ============================================================================


def classify(event: DragEvent) -> tuple[str, float]:
    """Return (relation, confidence) for the validated drop."""
    # Modifier overrides win first.
    for modifier in event.modifier_keys:
        if modifier in MODIFIER_OVERRIDES:
            return MODIFIER_OVERRIDES[modifier], CONF_MODIFIER

    assert event.target_kind is not None  # guard ensured this
    key = (event.source_kind, event.target_kind)
    relation = DISPATCH_TABLE.get(key)
    if relation is not None:
        return relation, CONF_DISPATCH

    return "references", CONF_FALLBACK


# ============================================================================
# Phase 3 — emit (replace-existing-same-pair rule)
# ============================================================================


def emit_edit(
    event: DragEvent, relation: str, confidence: float, graph: GraphState
) -> ConnectionEdit:
    """Emit the ConnectionEdit. Replaces-existing-same-pair if found."""
    assert event.target_id is not None  # guard ensured this

    existing_diff_relation = any(
        e.source == event.source_id
        and e.target == event.target_id
        and e.relation != relation
        for e in graph.connections
    )
    operation = "replace" if existing_diff_relation else "add"

    provenance_parts = ["drag-drop"]
    for modifier in event.modifier_keys:
        if modifier in MODIFIER_OVERRIDES:
            provenance_parts.append(f"modifier:{modifier}")
    provenance = ";".join(provenance_parts)

    return ConnectionEdit(
        operation=operation,
        source=event.source_id,
        relation=relation,
        target=event.target_id,
        confidence=confidence,
        provenance=provenance,
    )


# ============================================================================
# Phase 4 — project (pure functional next-state)
# ============================================================================


def project_next_state(current: GraphState, edit: ConnectionEdit | None) -> GraphState:
    """Project next graph state. Pure — does not mutate `current`."""
    if edit is None:
        return current  # no edit = no change

    new_connections = list(current.connections)
    if edit.operation == "replace":
        new_connections = [
            e for e in new_connections
            if not (e.source == edit.source and e.target == edit.target)
        ]
    elif edit.operation == "remove":
        new_connections = [
            e for e in new_connections
            if not (
                e.source == edit.source
                and e.relation == edit.relation
                and e.target == edit.target
            )
        ]
    new_connections.append(Edge(edit.source, edit.relation, edit.target))

    return GraphState(
        nodes=current.nodes,
        connections=new_connections,
        tier_map=current.tier_map,
    )


# ============================================================================
# Phase 5 — rejection trace + dispatch orchestration
# ============================================================================


def rejection_message(rejection: RejectionReason | None) -> str | None:
    if rejection is None:
        return None
    return f"{rejection.kind}: {rejection.detail}"


_TICK_COUNTER = 0


def _next_tick_id() -> str:
    """Monotonically-increasing tick identifier — keeps batched events tied."""
    global _TICK_COUNTER
    _TICK_COUNTER += 1
    return f"tick-{_TICK_COUNTER:012d}"


def dispatch(
    event: DragEvent,
    graph: GraphState,
    registry: RendererRegistry | None = None,
) -> DispatchResult:
    """Top-level dispatch — orchestrates the five phases.

    Wave-2 change: returns a `GraphMutationEvent` alongside the legacy fields
    so downstream consumers (MCP write path, undo stack, render-tick) can
    subscribe to a single structured signal.
    """
    if registry is None:
        registry = get_registry()
    tick_id = _next_tick_id()

    valid, rejection = guard(event, graph, registry=registry)
    if valid is None:
        return DispatchResult(
            edit=None,
            next_state=graph,
            rejection=rejection_message(rejection),
            mutation_event=GraphMutationEvent(
                event_type="rejected",
                edit=None,
                rejection=rejection,
                emitted_at=time.time(),
                source_tick=tick_id,
            ),
        )

    relation, confidence = classify(valid)
    edit = emit_edit(valid, relation, confidence, graph)
    next_state = project_next_state(graph, edit)

    event_type = {
        "add": "connection_add",
        "replace": "connection_replace",
        "remove": "connection_remove",
    }.get(edit.operation, "connection_add")

    return DispatchResult(
        edit=edit,
        next_state=next_state,
        rejection=None,
        mutation_event=GraphMutationEvent(
            event_type=event_type,
            edit=edit,
            rejection=None,
            emitted_at=time.time(),
            source_tick=tick_id,
        ),
    )


# ============================================================================
# Subscriber hooks — downstream consumers register here
# ============================================================================


_MUTATION_SUBSCRIBERS: list = []  # callables: (GraphMutationEvent) -> None


def subscribe_to_mutations(callback) -> None:
    """Register a callback to fire on every dispatch's mutation_event.

    Used by:
        - the MCP write path (calls `alethea.mcp.relate(edit.source, edit.relation, edit.target)`)
        - the undo stack (records each non-rejected edit)
        - the render-tick pipeline (refreshes the next render)
        - any audit/telemetry surface
    """
    _MUTATION_SUBSCRIBERS.append(callback)


def fire_subscribers(event: GraphMutationEvent) -> None:
    """Notify every registered subscriber. Failures don't abort other callbacks."""
    log = logging.getLogger("drag_drop_dispatcher")
    for cb in _MUTATION_SUBSCRIBERS:
        try:
            cb(event)
        except Exception as e:
            log.warning("subscriber %r failed: %s", cb, e)


def dispatch_and_notify(
    event: DragEvent,
    graph: GraphState,
    registry: RendererRegistry | None = None,
) -> DispatchResult:
    """`dispatch()` + fire subscriber hooks. The default entry-point for the
    production sidecar — calling `dispatch_and_notify` instead of `dispatch`
    is the only delta from the pure-function path.
    """
    result = dispatch(event, graph, registry=registry)
    fire_subscribers(result.mutation_event)
    return result


# ============================================================================
# Serializers — for the JSONL transport / HTTP sidecar
# ============================================================================


def event_from_dict(d: dict[str, Any]) -> DragEvent:
    return DragEvent(
        source_id=d["source_id"],
        source_kind=d["source_kind"],
        source_tier=WorldlineTier.parse(d.get("source_tier")),
        target_id=d.get("target_id"),
        target_kind=d.get("target_kind"),
        target_tier=WorldlineTier.parse(d.get("target_tier")),
        modifier_keys=tuple(d.get("modifier_keys", [])),
        pointer_position=Point(**d.get("pointer_position", {"x": 0.0, "y": 0.0})),
    )


def graph_from_dict(d: dict[str, Any]) -> GraphState:
    return GraphState(
        nodes=d.get("nodes", {}),
        connections=[Edge(**e) for e in d.get("connections", [])],
        tier_map={
            k: WorldlineTier.parse(v) or WorldlineTier.planned
            for k, v in d.get("tier_map", {}).items()
        },
    )


def result_to_dict(result: DispatchResult) -> dict[str, Any]:
    return {
        "edit": dataclasses.asdict(result.edit) if result.edit else None,
        "next_state": {
            "connections": [dataclasses.asdict(e) for e in result.next_state.connections],
        },
        "rejection": result.rejection,
        "mutation_event": {
            "event_type": result.mutation_event.event_type,
            "source_tick": result.mutation_event.source_tick,
            "emitted_at": result.mutation_event.emitted_at,
        },
    }


# ============================================================================
# CLI
# ============================================================================


def _serve_jsonl(stream_in=sys.stdin, stream_out=sys.stdout) -> int:
    """JSONL request/response loop — one event per line.

    Each line is a JSON object:
        {"event": {...DragEvent...}, "graph": {...GraphState...}}
    Each output line is the dispatch result as JSON.
    """
    for line in stream_in:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
            event = event_from_dict(payload["event"])
            graph = graph_from_dict(payload.get("graph", {}))
            result = dispatch(event, graph)
            print(json.dumps(result_to_dict(result)), file=stream_out, flush=True)
        except Exception as e:
            print(json.dumps({"error": str(e)}), file=stream_out, flush=True)
    return 0


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument(
        "--test", action="store_true", help="Run the test suite via pytest"
    )
    parser.add_argument(
        "--bench", action="store_true", help="Benchmark dispatch latency"
    )
    parser.add_argument(
        "--serve", action="store_true", help="JSONL request/response loop on stdin"
    )
    parser.add_argument(
        "--validate-registry",
        action="store_true",
        help="Print the registry summary before running",
    )
    args = parser.parse_args(argv)

    if args.validate_registry:
        reg = get_registry()
        print(f"registry: {reg.kinds_count} kinds, {len(reg.errors)} errors")
        if reg.errors:
            for e in reg.errors:
                print(f"  [{e.error_type}] {e.kind}: {e.detail}")
            return 1

    if args.test:
        import pytest
        return pytest.main([str(Path(__file__).resolve().parent / "tests")])

    if args.bench:
        # Synthesize a handful of representative events; loop 1000 times.
        events = [
            DragEvent(
                source_id="t1", source_kind="tasks-list-item",
                source_tier=WorldlineTier.in_progress,
                target_id="c1", target_kind="calendar-entry",
                target_tier=WorldlineTier.in_progress,
            ),
            DragEvent(
                source_id="i1", source_kind="idea-card",
                source_tier=WorldlineTier.planned,
                target_id="p1", target_kind="planned-node",
                target_tier=WorldlineTier.planned,
            ),
        ]
        graph = GraphState()
        registry = get_registry()
        t0 = time.perf_counter()
        n = 0
        for _ in range(1000):
            for ev in events:
                dispatch(ev, graph, registry=registry)
                n += 1
        elapsed = time.perf_counter() - t0
        per_us = (elapsed / n) * 1_000_000
        print(f"Bench: {n} dispatches in {elapsed:.3f}s = {per_us:.1f} µs/call")
        return 0

    if args.serve:
        return _serve_jsonl()

    # Default: print a one-line status.
    reg = get_registry()
    print(
        f"drag_drop_dispatcher ready. registry: {reg.kinds_count} kinds. "
        f"dispatch table: {len(DISPATCH_TABLE)} rows."
    )
    print("Run with --test, --bench, or --serve.")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
