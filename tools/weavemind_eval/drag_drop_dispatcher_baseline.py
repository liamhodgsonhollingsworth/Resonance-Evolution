"""Python baseline implementation of the drag-and-drop dispatcher.

Schema-version: 1
Filed: 2026-05-29 per WeaveMind evaluation gate (MVP plan Wave 1 / Subagent W1-A).
Authored by: session jovial-margulis-52985e in worktree
             C:/Users/Liam/Desktop/Alethea/.claude/worktrees/jovial-margulis-52985e/

This is the side-by-side counterpart to drag_drop_dispatcher.weft. Same input
shape (DragEvent), same output shape (DispatchResult). Same dispatch table.
Same tier-window rule. Both are graded on the same 12-event adversarial test
set in test_cases.json. Scoring matrix + verdict in EVALUATION.md.

Goal of this baseline: produce the most idiomatic-Python implementation of
the same behavior, so the comparison is "Python at its best vs Weft at its
best" rather than "Python written to mimic Weft."

Invocation:
    python drag_drop_dispatcher_baseline.py --test test_cases.json
    python drag_drop_dispatcher_baseline.py --bench

Algorithm (matches the Weft program's five phases):
    Phase 1 — guard: validate self-drop, null target, tier window, kind registry
    Phase 2 — classify: dispatch (source_kind, target_kind, modifiers) -> relation
    Phase 3 — emit: ConnectionEdit with operation/source/relation/target
    Phase 4 — project: compute next graph state from current + edit
    Phase 5 — rejection trace: tooltip text when guard rejects
"""

from __future__ import annotations

import argparse
import dataclasses
import enum
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ============================================================================
# Type model — the equivalent of Weft's port types
# ============================================================================

class WorldlineTier(enum.IntEnum):
    """Ordered tiers; ordering enables the tier-window check."""

    sci_fi = 0
    planned = 1
    in_progress = 2
    realized = 3
    maintained = 4

    @classmethod
    def parse(cls, value: str | None) -> "WorldlineTier | None":
        if value is None:
            return None
        normalized = value.replace("-", "_").lower()
        return cls[normalized] if normalized in cls.__members__ else None


# Renderer kinds (from the MVP plan Section 2b). New kinds extend this list.
RENDERER_KINDS: set[str] = {
    "window", "panel", "palette-item", "tasks-list", "tasks-list-item",
    "calendar", "calendar-entry", "idea-card", "chat-thread", "chat-bubble",
    "3d-canvas", "render-bundle", "painterly-output", "paste-target", "wire",
    "right-click-menu", "workspace", "camera", "viewer-state",
    "planned-node", "sci-fi-node", "renderer-node",
}

# Connection relations (from substrate canonical vocab).
CONNECTION_RELATIONS: set[str] = {
    "depends-on", "composes-with", "realizes", "implements", "displays",
    "references", "crystallizes-to", "superseded-by", "instantiates",
    "spawns", "displayed_by",
}


@dataclass(frozen=True)
class Point:
    x: float
    y: float


@dataclass(frozen=True)
class DragEvent:
    """The drag event the website UI emits."""

    source_id: str
    source_kind: str
    source_tier: WorldlineTier | None
    target_id: str | None  # null when dropped on empty canvas
    target_kind: str | None
    target_tier: WorldlineTier | None
    modifier_keys: tuple[str, ...] = ()  # "ctrl" | "shift" | "alt"
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
    kind: str  # "self_drop" | "null_target" | "invalid_tier" | "invalid_kind"
    detail: str


@dataclass(frozen=True)
class DispatchResult:
    """The Group's output ports — what the renderer-tick consumes."""

    edit: ConnectionEdit | None
    next_state: GraphState
    rejection: str | None


# ============================================================================
# Phase 1 — guard
# ============================================================================

TIER_WINDOW = 2  # tier-skip-blocked window (sci-fi -> realized = 3 hops, BLOCKED)


def guard(event: DragEvent, graph: GraphState) -> tuple[DragEvent | None, RejectionReason | None]:
    """Validate the drag event. Returns (valid_event, rejection) — exactly one is non-null."""
    # Rule 1 — self-drop
    if event.source_id == event.target_id:
        return None, RejectionReason("self_drop", "cannot drop a node on itself")

    # Rule 2 — null target
    if event.target_id is None or event.target_kind is None:
        return None, RejectionReason("null_target", "drop on empty canvas is layout-only, not a connection")

    # Rule 3 — invalid kind registry
    if event.source_kind not in RENDERER_KINDS:
        return None, RejectionReason("invalid_kind", f"source kind {event.source_kind!r} not in registry")
    if event.target_kind not in RENDERER_KINDS:
        return None, RejectionReason("invalid_kind", f"target kind {event.target_kind!r} not in registry")

    # Rule 4 — tier-window
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
# Phase 2 — classify
# ============================================================================

# Dispatch table: (source_kind, target_kind) -> default_relation.
# Adding a new (kind, kind) pair = one row.
DISPATCH_TABLE: dict[tuple[str, str], str] = {
    ("tasks-list-item", "calendar-entry"): "realizes",
    ("tasks-list-item", "tasks-list-item"): "depends-on",
    ("chat-bubble", "idea-card"): "references",
    ("idea-card", "idea-card"): "composes-with",
    ("idea-card", "planned-node"): "crystallizes-to",
    ("sci-fi-node", "planned-node"): "crystallizes-to",
    ("render-bundle", "painterly-output"): "displayed_by",
    ("3d-canvas", "camera"): "composes-with",
    ("paste-target", "renderer-node"): "instantiates",
    ("palette-item", "workspace"): "spawns",
    ("panel", "window"): "displays",
    ("chat-thread", "chat-bubble"): "displays",
}

MODIFIER_OVERRIDES: dict[str, str] = {
    "ctrl": "references",
    "shift": "composes-with",
    "alt": "depends-on",
}


def classify(event: DragEvent) -> tuple[str | None, float]:
    """Return (relation, confidence) for the drop, or (None, 0.0) when no rule fires."""
    # Modifier overrides win first (per UI convention).
    for modifier in event.modifier_keys:
        if modifier in MODIFIER_OVERRIDES:
            return MODIFIER_OVERRIDES[modifier], 0.95

    # Dispatch table.
    assert event.target_kind is not None  # guard ensured this
    key = (event.source_kind, event.target_kind)
    relation = DISPATCH_TABLE.get(key)
    if relation is not None:
        return relation, 0.85

    # Fallback: "references" with low confidence.
    return "references", 0.3


# ============================================================================
# Phase 3 — emit
# ============================================================================


def emit_edit(event: DragEvent, relation: str, confidence: float, graph: GraphState) -> ConnectionEdit:
    """Emit the ConnectionEdit. Replaces-existing-same-pair if found."""
    assert event.target_id is not None  # guard ensured this

    # Check for existing same-pair connection (different relation -> replace).
    existing_diff_relation = any(
        edge.source == event.source_id
        and edge.target == event.target_id
        and edge.relation != relation
        for edge in graph.connections
    )
    operation = "replace" if existing_diff_relation else "add"

    provenance_parts = ["drag-drop on UI"]
    for modifier in event.modifier_keys:
        if modifier in MODIFIER_OVERRIDES:
            provenance_parts.append(f"modifier-override:{modifier}")
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
# Phase 4 — project
# ============================================================================


def project_next_state(current: GraphState, edit: ConnectionEdit | None) -> GraphState:
    """Pure functional projection of next graph state."""
    if edit is None:
        return current  # no edit -> no change

    new_connections = list(current.connections)
    if edit.operation == "replace":
        new_connections = [
            e for e in new_connections
            if not (e.source == edit.source and e.target == edit.target)
        ]
    elif edit.operation == "remove":
        new_connections = [
            e for e in new_connections
            if not (e.source == edit.source and e.relation == edit.relation and e.target == edit.target)
        ]
    new_connections.append(Edge(edit.source, edit.relation, edit.target))

    return GraphState(
        nodes=current.nodes,
        connections=new_connections,
        tier_map=current.tier_map,
    )


# ============================================================================
# Phase 5 — rejection trace + Group composition
# ============================================================================


def rejection_message(rejection: RejectionReason | None) -> str | None:
    if rejection is None:
        return None
    return f"{rejection.kind}: {rejection.detail}"


def dispatch(event: DragEvent, graph: GraphState) -> DispatchResult:
    """Top-level dispatch — the Group's body in Python form.

    Mirrors the Weft program's five phases. Each phase produces a typed value
    that the next phase consumes; null-propagation in the Weft sense is
    `None`-propagation here.
    """
    valid, rejection = guard(event, graph)
    if valid is None:
        return DispatchResult(edit=None, next_state=graph, rejection=rejection_message(rejection))

    relation, confidence = classify(valid)
    if relation is None:
        return DispatchResult(edit=None, next_state=graph, rejection="classify_failed: no rule matched")

    edit = emit_edit(valid, relation, confidence, graph)
    next_state = project_next_state(graph, edit)
    return DispatchResult(edit=edit, next_state=next_state, rejection=None)


# ============================================================================
# Test harness
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
        tier_map={k: WorldlineTier.parse(v) or WorldlineTier.planned for k, v in d.get("tier_map", {}).items()},
    )


def result_to_dict(result: DispatchResult) -> dict[str, Any]:
    return {
        "edit": dataclasses.asdict(result.edit) if result.edit else None,
        "next_state": {
            "connections": [dataclasses.asdict(e) for e in result.next_state.connections],
        },
        "rejection": result.rejection,
    }


def run_test_set(test_path: Path) -> int:
    """Run every case in test_cases.json; return exit code (0 = all pass)."""
    cases = json.loads(test_path.read_text(encoding="utf-8"))["cases"]
    failures: list[str] = []
    timings: list[float] = []

    for case in cases:
        event = event_from_dict(case["event"])
        graph = graph_from_dict(case.get("initial_graph", {}))

        t0 = time.perf_counter()
        result = dispatch(event, graph)
        timings.append(time.perf_counter() - t0)

        actual = result_to_dict(result)
        expected = case["expected"]

        # Spot-check the load-bearing fields.
        ok = True
        if expected.get("edit") is None:
            if actual["edit"] is not None:
                ok = False
        else:
            if actual["edit"] is None:
                ok = False
            else:
                for field_name in ("operation", "source", "relation", "target"):
                    if actual["edit"][field_name] != expected["edit"][field_name]:
                        ok = False

        if expected.get("rejection_kind") is not None:
            actual_rej = actual["rejection"] or ""
            if not actual_rej.startswith(expected["rejection_kind"]):
                ok = False

        status = "PASS" if ok else "FAIL"
        print(f"  [{status}] {case['name']}")
        if not ok:
            failures.append(case["name"])
            print(f"    expected: {expected}")
            print(f"    actual:   {actual}")

    n = len(cases)
    avg_us = (sum(timings) / n) * 1_000_000 if n else 0.0
    print(f"\nResult: {n - len(failures)}/{n} passed; avg dispatch latency = {avg_us:.1f} µs")
    if failures:
        print(f"Failures: {failures}")
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test", type=Path, default=Path(__file__).parent / "test_cases.json")
    parser.add_argument("--bench", action="store_true")
    args = parser.parse_args()

    if args.bench:
        # Run the test set 100 times to amortize startup.
        cases = json.loads(args.test.read_text(encoding="utf-8"))["cases"]
        t0 = time.perf_counter()
        for _ in range(100):
            for case in cases:
                event = event_from_dict(case["event"])
                graph = graph_from_dict(case.get("initial_graph", {}))
                dispatch(event, graph)
        elapsed = time.perf_counter() - t0
        n_total = 100 * len(cases)
        per_call_us = (elapsed / n_total) * 1_000_000
        print(f"Bench: {n_total} dispatches in {elapsed:.3f}s = {per_call_us:.1f} µs/call")
        return 0

    return run_test_set(args.test)


if __name__ == "__main__":
    sys.exit(main())
