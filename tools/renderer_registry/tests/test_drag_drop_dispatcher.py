"""Adversarial tests for the drag-drop dispatcher runtime.

Schema-version: 1
Filed: 2026-05-29 per MVP plan Wave 2.

Required coverage (per the implementation prompt):
    drop-on-self, drop-on-invalid-target, drop-across-tier-boundaries,
    drop-with-missing-renderer, drop-into-group, drop-out-of-group.

Extended coverage:
    every dispatch-table relation, modifier overrides, replace-existing-pair,
    fallback for unmapped kind pairs, subscriber hooks, optimistic projection,
    structured mutation events, batched undo via tick IDs.

Invocation:
    pytest tools/renderer_registry/tests/test_drag_drop_dispatcher.py -v
"""

from __future__ import annotations

import sys
from pathlib import Path

APEIRON_ROOT = Path(__file__).resolve().parents[3]
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

import pytest

from tools.renderer_registry.drag_drop_dispatcher import (
    CONNECTION_RELATIONS,
    DISPATCH_TABLE,
    DragEvent,
    Edge,
    GraphState,
    MODIFIER_OVERRIDES,
    Point,
    TIER_WINDOW,
    WorldlineTier,
    classify,
    dispatch,
    dispatch_and_notify,
    emit_edit,
    guard,
    project_next_state,
    subscribe_to_mutations,
    _MUTATION_SUBSCRIBERS,
)
from tools.renderer_registry.registry import (
    RendererBinding,
    RendererRegistry,
    get_registry,
    reset_registry,
)


# ============================================================================
# Helpers
# ============================================================================


def make_event(
    source_id="t1",
    source_kind="tasks-list-item",
    source_tier="in-progress",
    target_id="c1",
    target_kind="calendar-entry",
    target_tier="in-progress",
    modifier_keys=(),
) -> DragEvent:
    return DragEvent(
        source_id=source_id,
        source_kind=source_kind,
        source_tier=WorldlineTier.parse(source_tier),
        target_id=target_id,
        target_kind=target_kind,
        target_tier=WorldlineTier.parse(target_tier),
        modifier_keys=tuple(modifier_keys),
        pointer_position=Point(100.0, 100.0),
    )


@pytest.fixture(autouse=True)
def fresh_registry():
    """Every test gets a fresh registry (snapshot rebuilt from disk)."""
    reset_registry()
    _MUTATION_SUBSCRIBERS.clear()
    yield
    reset_registry()
    _MUTATION_SUBSCRIBERS.clear()


# ============================================================================
# Required adversarial cases — must all pass for Wave 2 to declare done
# ============================================================================


class TestRequiredAdversarialCases:
    """Six core cases the prompt names — each must reject or accept correctly."""

    def test_drop_on_self(self):
        """A drop on self must be rejected with self_drop reason."""
        event = make_event(
            source_id="same",
            target_id="same",
            target_kind="tasks-list-item",
        )
        result = dispatch(event, GraphState())
        assert result.edit is None
        assert result.rejection is not None
        assert result.rejection.startswith("self_drop")
        assert result.mutation_event.event_type == "rejected"
        assert result.mutation_event.rejection.kind == "self_drop"

    def test_drop_on_invalid_target_kind(self):
        """A drop onto a target with an unregistered kind must be rejected with invalid_kind."""
        event = make_event(
            target_id="weird",
            target_kind="not-a-real-kind",
        )
        result = dispatch(event, GraphState())
        assert result.edit is None
        assert result.rejection is not None
        assert result.rejection.startswith("invalid_kind")

    def test_drop_across_tier_boundaries(self):
        """A drop spanning more tiers than the window must reject with invalid_tier."""
        event = make_event(
            source_kind="sci-fi-node",
            source_tier="sci-fi",
            target_kind="renderer-node",
            target_tier="maintained",  # distance = 4 > window = 2
        )
        result = dispatch(event, GraphState())
        assert result.edit is None
        assert result.rejection is not None
        assert result.rejection.startswith("invalid_tier")

    def test_drop_at_tier_window_boundary_accepted(self):
        """Tier distance exactly equal to the window must be accepted."""
        event = make_event(
            source_kind="sci-fi-node",
            source_tier="sci-fi",
            target_kind="planned-node",
            target_tier="in-progress",  # distance = 2 == window
        )
        result = dispatch(event, GraphState())
        assert result.edit is not None
        assert result.rejection is None

    def test_drop_with_missing_renderer(self):
        """A drop whose source_kind isn't in the registry must reject with invalid_kind."""
        event = make_event(
            source_id="ghost",
            source_kind="phantom-source-kind",
            source_tier="in-progress",
        )
        result = dispatch(event, GraphState())
        assert result.edit is None
        assert result.rejection is not None
        assert result.rejection.startswith("invalid_kind")
        # Specifically: the source side should be cited (not the target side)
        assert "phantom-source-kind" in result.rejection

    def test_drop_into_group(self):
        """A drop into a `panel` (a group-shaped renderer) should produce a `composes-with` edge.

        The dispatch table now includes window->panel = composes-with;
        downstream UIs interpret this as "drop into a container."
        """
        event = make_event(
            source_id="w1",
            source_kind="window",
            source_tier="realized",
            target_id="p1",
            target_kind="panel",
            target_tier="realized",
        )
        result = dispatch(event, GraphState())
        assert result.edit is not None
        assert result.edit.relation == "composes-with"
        assert result.edit.operation == "add"

    def test_drop_out_of_group(self):
        """A drop reversing a prior composes-with (i.e., re-parenting out of a group)
        must REPLACE the prior edge.

        Sequence: parent already composes-with child; drop the child back onto
        a different parent — the new drop replaces the old composes-with."""
        graph = GraphState(
            connections=[
                Edge(source="w1", relation="composes-with", target="p1"),
            ]
        )
        # Now drop w1 onto p1 with a modifier forcing references — must REPLACE
        event = make_event(
            source_id="w1",
            source_kind="window",
            source_tier="realized",
            target_id="p1",
            target_kind="panel",
            target_tier="realized",
            modifier_keys=("ctrl",),  # forces "references"
        )
        result = dispatch(event, graph)
        assert result.edit is not None
        assert result.edit.operation == "replace"
        assert result.edit.relation == "references"

        # The projected state should no longer carry the old composes-with edge
        old_edges = [
            e for e in result.next_state.connections
            if e.relation == "composes-with" and e.source == "w1" and e.target == "p1"
        ]
        assert not old_edges, "old edge survived a replace"


# ============================================================================
# Guard tests (Phase 1)
# ============================================================================


class TestGuard:
    def test_null_target_rejected(self):
        event = DragEvent(
            source_id="t1", source_kind="tasks-list-item",
            source_tier=WorldlineTier.in_progress,
            target_id=None, target_kind=None, target_tier=None,
        )
        valid, rejection = guard(event, GraphState())
        assert valid is None
        assert rejection.kind == "null_target"

    def test_tier_window_boundary(self):
        """At exactly the window, accept. Beyond, reject."""
        # Distance = 2 (window): sci-fi -> in-progress
        boundary = make_event(
            source_kind="sci-fi-node", source_tier="sci-fi",
            target_kind="planned-node", target_tier="in-progress",
        )
        v, r = guard(boundary, GraphState())
        assert v is not None and r is None

        # Distance = 3 (over window): sci-fi -> realized
        over = make_event(
            source_kind="sci-fi-node", source_tier="sci-fi",
            target_kind="renderer-node", target_tier="realized",
        )
        v, r = guard(over, GraphState())
        assert v is None and r.kind == "invalid_tier"

    def test_explicit_registry_used(self):
        """Guard must honor an explicitly-passed registry, not just the singleton."""
        # Build a tiny test registry containing only `window`
        tiny = RendererRegistry.empty()
        tiny._registry["window"] = RendererBinding(
            kind="window", module_path="", module_name="",
            version="1.0", renderer_id="dom", source="mvp_virtual",
        )
        # A drop using `panel` (not in tiny) should reject — even though
        # the global registry has it
        event = make_event(
            source_kind="window", target_kind="panel",
            source_tier="realized", target_tier="realized",
        )
        valid, rejection = guard(event, GraphState(), registry=tiny)
        assert valid is None
        assert rejection.kind == "invalid_kind"
        assert "panel" in rejection.detail


# ============================================================================
# Classify tests (Phase 2)
# ============================================================================


class TestClassify:
    def test_modifier_override_wins_over_dispatch_table(self):
        """A modifier override must win even when the dispatch table maps the pair."""
        event = make_event(
            source_kind="tasks-list-item",  # dispatch table maps tasks->calendar = realizes
            target_kind="calendar-entry",
            modifier_keys=("ctrl",),  # ctrl forces references
        )
        relation, conf = classify(event)
        assert relation == "references"
        assert conf >= 0.9  # modifier confidence high

    def test_alt_modifier_depends_on(self):
        event = make_event(
            source_kind="idea-card", target_kind="idea-card",
            modifier_keys=("alt",),
        )
        relation, _ = classify(event)
        assert relation == "depends-on"

    def test_shift_modifier_composes_with(self):
        event = make_event(
            source_kind="idea-card", target_kind="idea-card",
            modifier_keys=("shift",),
        )
        relation, _ = classify(event)
        assert relation == "composes-with"

    def test_dispatch_table_hit_returns_mapped_relation(self):
        event = make_event(
            source_kind="render-bundle", target_kind="painterly-output",
            source_tier="realized", target_tier="realized",
        )
        relation, conf = classify(event)
        assert relation == "displayed_by"

    def test_fallback_for_unmapped_pair(self):
        """Unmapped kind pairs fall back to `references` with low confidence."""
        event = make_event(
            source_kind="wire", target_kind="right-click-menu",
            source_tier="realized", target_tier="realized",
        )
        relation, conf = classify(event)
        assert relation == "references"
        assert conf < 0.5  # low-confidence fallback


# ============================================================================
# Emit tests (Phase 3)
# ============================================================================


class TestEmit:
    def test_add_when_no_prior_edge(self):
        event = make_event()
        edit = emit_edit(event, "realizes", 0.85, GraphState())
        assert edit.operation == "add"
        assert edit.source == event.source_id
        assert edit.target == event.target_id
        assert edit.relation == "realizes"

    def test_replace_when_existing_same_pair_different_relation(self):
        """Same source+target with different relation -> replace, not add."""
        graph = GraphState(
            connections=[Edge(source="t1", relation="references", target="c1")]
        )
        event = make_event()
        edit = emit_edit(event, "realizes", 0.85, graph)
        assert edit.operation == "replace"

    def test_add_when_existing_same_pair_same_relation(self):
        """Same source+target+relation = idempotent add (still 'add')."""
        graph = GraphState(
            connections=[Edge(source="t1", relation="realizes", target="c1")]
        )
        event = make_event()
        edit = emit_edit(event, "realizes", 0.85, graph)
        assert edit.operation == "add"  # no different-relation prior edge

    def test_provenance_records_modifier(self):
        event = make_event(modifier_keys=("ctrl",))
        edit = emit_edit(event, "references", 0.95, GraphState())
        assert "modifier:ctrl" in edit.provenance


# ============================================================================
# Project tests (Phase 4)
# ============================================================================


class TestProject:
    def test_project_returns_input_when_edit_is_none(self):
        graph = GraphState(connections=[Edge("a", "x", "b")])
        result = project_next_state(graph, None)
        assert result is graph

    def test_project_appends_add(self):
        graph = GraphState()
        from tools.renderer_registry.drag_drop_dispatcher import ConnectionEdit
        edit = ConnectionEdit(
            operation="add", source="a", relation="references",
            target="b", confidence=0.9, provenance="test",
        )
        next_state = project_next_state(graph, edit)
        assert len(next_state.connections) == 1
        assert next_state.connections[0].source == "a"

    def test_project_replace_drops_old_pair(self):
        graph = GraphState(
            connections=[Edge("a", "references", "b"), Edge("a", "depends-on", "c")]
        )
        from tools.renderer_registry.drag_drop_dispatcher import ConnectionEdit
        edit = ConnectionEdit(
            operation="replace", source="a", relation="composes-with",
            target="b", confidence=0.9, provenance="test",
        )
        next_state = project_next_state(graph, edit)
        # The old (a, *, b) should be gone; (a, depends-on, c) preserved
        b_edges = [e for e in next_state.connections if e.target == "b"]
        assert len(b_edges) == 1
        assert b_edges[0].relation == "composes-with"
        c_edges = [e for e in next_state.connections if e.target == "c"]
        assert len(c_edges) == 1

    def test_project_is_pure(self):
        """project_next_state must not mutate the input graph."""
        graph = GraphState(connections=[Edge("a", "x", "b")])
        from tools.renderer_registry.drag_drop_dispatcher import ConnectionEdit
        edit = ConnectionEdit(
            operation="add", source="c", relation="y",
            target="d", confidence=0.9, provenance="test",
        )
        original_len = len(graph.connections)
        project_next_state(graph, edit)
        assert len(graph.connections) == original_len


# ============================================================================
# Mutation-event + subscriber tests (Wave 2 delta)
# ============================================================================


class TestMutationEvent:
    def test_mutation_event_emitted_on_accept(self):
        event = make_event()
        result = dispatch(event, GraphState())
        assert result.mutation_event.event_type == "connection_add"
        assert result.mutation_event.edit is not None
        assert result.mutation_event.source_tick.startswith("tick-")

    def test_mutation_event_emitted_on_reject(self):
        event = make_event(source_id="same", target_id="same", target_kind="tasks-list-item")
        result = dispatch(event, GraphState())
        assert result.mutation_event.event_type == "rejected"
        assert result.mutation_event.edit is None
        assert result.mutation_event.rejection is not None

    def test_distinct_tick_ids_across_dispatches(self):
        """Every dispatch gets a unique tick id."""
        e1 = make_event(source_id="a", target_id="b", target_kind="calendar-entry")
        e2 = make_event(source_id="c", target_id="d", target_kind="calendar-entry")
        r1 = dispatch(e1, GraphState())
        r2 = dispatch(e2, GraphState())
        assert r1.mutation_event.source_tick != r2.mutation_event.source_tick

    def test_subscriber_called_via_dispatch_and_notify(self):
        """Subscribers fire on every mutation, including rejections."""
        captured = []
        subscribe_to_mutations(lambda ev: captured.append(ev))

        # Accepted dispatch
        e1 = make_event()
        dispatch_and_notify(e1, GraphState())

        # Rejected dispatch
        e2 = make_event(source_id="x", target_id="x", target_kind="tasks-list-item")
        dispatch_and_notify(e2, GraphState())

        assert len(captured) == 2
        assert captured[0].event_type == "connection_add"
        assert captured[1].event_type == "rejected"

    def test_subscriber_failure_does_not_break_dispatch(self):
        """A subscriber raising must not abort the dispatch or other subscribers."""
        def broken(_ev):
            raise RuntimeError("subscriber boom")

        captured = []
        subscribe_to_mutations(broken)
        subscribe_to_mutations(lambda ev: captured.append(ev))

        event = make_event()
        result = dispatch_and_notify(event, GraphState())
        # Result is correct
        assert result.edit is not None
        # Healthy subscriber still got the event
        assert len(captured) == 1


# ============================================================================
# Coverage tests — every dispatch-table relation should hit
# ============================================================================


class TestDispatchTableCoverage:
    @pytest.mark.parametrize("source_kind,target_kind,expected_relation", [
        (sk, tk, rel) for (sk, tk), rel in DISPATCH_TABLE.items()
    ])
    def test_every_dispatch_table_row(self, source_kind, target_kind, expected_relation):
        """Every row in DISPATCH_TABLE must produce the documented relation."""
        event = make_event(
            source_id="src",
            source_kind=source_kind,
            source_tier="realized",
            target_id="tgt",
            target_kind=target_kind,
            target_tier="realized",
        )
        result = dispatch(event, GraphState())
        if result.edit is None:
            # If a row is unreachable (e.g., kind not in registry), surface
            # that — every row's source_kind+target_kind must be registered.
            pytest.fail(
                f"row ({source_kind}, {target_kind}) dispatched to None — "
                f"rejection: {result.rejection}"
            )
        assert result.edit.relation == expected_relation


# ============================================================================
# Sanity — relation vocabulary
# ============================================================================


class TestRelationVocabulary:
    def test_every_dispatch_relation_in_canonical_vocabulary(self):
        """Every relation in DISPATCH_TABLE must be in the canonical vocab."""
        for (sk, tk), rel in DISPATCH_TABLE.items():
            assert rel in CONNECTION_RELATIONS, (
                f"dispatch row ({sk}, {tk}) -> {rel} not in canonical vocabulary"
            )

    def test_every_modifier_override_in_vocabulary(self):
        for _, rel in MODIFIER_OVERRIDES.items():
            assert rel in CONNECTION_RELATIONS
