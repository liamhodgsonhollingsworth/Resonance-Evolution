extends SceneTree
## Headless test suite for renderers/construction_sequencer.gd (ConstructionSequencer, Wave 2 item
## 2.2, part of DQ-6963c689's lane):
##
##   godot --headless --path godot -s res://headless_construction_sequencer_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_order_ring_by_ring_groups_by_ring_then_arc() and ok
	ok = _test_order_radial_out_groups_by_arc_then_ring() and ok
	ok = _test_order_angular_sweep_same_key_as_radial_out() and ok
	ok = _test_order_unknown_mode_falls_back_to_default() and ok
	ok = _test_order_chunks_does_not_mutate_input() and ok
	ok = _test_order_chunks_preserves_all_chunks() and ok
	ok = _test_clamp_tick_interval_bounds() and ok
	ok = _test_sequence_default_ordering_is_ring_by_ring() and ok
	ok = _test_sequence_advance_emits_one_per_interval() and ok
	ok = _test_sequence_advance_catches_up_multiple_due_chunks() and ok
	ok = _test_sequence_advance_never_exceeds_total() and ok
	ok = _test_sequence_is_done_and_progress() and ok
	ok = _test_sequence_last_event_flagged_is_last() and ok
	ok = _test_sequence_carries_generation_id() and ok
	ok = _test_sequence_advance_batch_ignores_elapsed_time() and ok
	ok = _test_sequence_reset_restarts_cursor() and ok
	ok = _test_build_convenience_matches_manual_construction() and ok
	ok = _test_composes_with_real_ring_scaffold_wedge_chunks() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _sample_chunks() -> Array:
	# 3 rings x 4 arcs, deliberately shuffled -- exercises the sort, not just an already-sorted list.
	var chunks: Array = []
	for ring in [2, 1, 3]:
		for arc in [3, 0, 2, 1]:
			chunks.append({"ring": ring, "arc": arc, "radius": float(ring) * 4.0})
	return chunks


# ── order_chunks ─────────────────────────────────────────────────────────────────────────────────

func _test_order_ring_by_ring_groups_by_ring_then_arc() -> bool:
	var ordered := ConstructionSequencer.order_chunks(_sample_chunks(), "ring-by-ring")
	var ok := true
	var prev_ring := -1
	var prev_arc := -1
	for c in ordered:
		var r: int = c["ring"]
		var a: int = c["arc"]
		if r != prev_ring:
			ok = ok and r > prev_ring
			prev_arc = -1
		else:
			ok = ok and a > prev_arc
		prev_ring = r
		prev_arc = a
	return _check("order_chunks: ring-by-ring -> non-decreasing (ring, arc), ring 1 fully before ring 2", ok)

func _test_order_radial_out_groups_by_arc_then_ring() -> bool:
	var ordered := ConstructionSequencer.order_chunks(_sample_chunks(), "radial-out")
	var ok := true
	var prev_arc := -1
	var prev_ring := -1
	for c in ordered:
		var r: int = c["ring"]
		var a: int = c["arc"]
		if a != prev_arc:
			ok = ok and a > prev_arc
			prev_ring = -1
		else:
			ok = ok and r > prev_ring
		prev_arc = a
		prev_ring = r
	return _check("order_chunks: radial-out -> non-decreasing (arc, ring), arc 0 fully before arc 1", ok)

func _test_order_angular_sweep_same_key_as_radial_out() -> bool:
	var chunks := _sample_chunks()
	var radial := ConstructionSequencer.order_chunks(chunks, "radial-out")
	var sweep := ConstructionSequencer.order_chunks(chunks, "angular-sweep")
	var ok: bool = radial.size() == sweep.size()
	for i in radial.size():
		ok = ok and radial[i]["ring"] == sweep[i]["ring"] and radial[i]["arc"] == sweep[i]["arc"]
	return _check("order_chunks: angular-sweep sorts identically to radial-out (grouping is caller-side, per file docstring)", ok)

func _test_order_unknown_mode_falls_back_to_default() -> bool:
	var chunks := _sample_chunks()
	var unknown := ConstructionSequencer.order_chunks(chunks, "not-a-real-mode")
	var default_order := ConstructionSequencer.order_chunks(chunks, ConstructionSequencer.DEFAULT_ORDERING_MODE)
	var ok: bool = unknown.size() == default_order.size()
	for i in unknown.size():
		ok = ok and unknown[i]["ring"] == default_order[i]["ring"] and unknown[i]["arc"] == default_order[i]["arc"]
	return _check("order_chunks: unrecognized ordering_mode falls back to DEFAULT_ORDERING_MODE (ring-by-ring)", ok)

func _test_order_chunks_does_not_mutate_input() -> bool:
	var chunks := _sample_chunks()
	var first_before: Dictionary = chunks[0]
	ConstructionSequencer.order_chunks(chunks, "ring-by-ring")
	var ok: bool = chunks[0] == first_before  # original array's element order untouched
	return _check("order_chunks: never mutates the caller's chunk_list", ok)

func _test_order_chunks_preserves_all_chunks() -> bool:
	var chunks := _sample_chunks()
	var ordered := ConstructionSequencer.order_chunks(chunks, "ring-by-ring")
	var ok: bool = ordered.size() == chunks.size()
	var seen: Dictionary = {}
	for c in ordered:
		seen["%d_%d" % [int(c["ring"]), int(c["arc"])]] = true
	ok = ok and seen.size() == chunks.size()
	return _check("order_chunks: every input chunk appears exactly once in the output", ok)


# ── clamp_tick_interval ─────────────────────────────────────────────────────────────────────────

func _test_clamp_tick_interval_bounds() -> bool:
	var ok := true
	ok = ok and ConstructionSequencer.clamp_tick_interval(5) == ConstructionSequencer.MIN_TICK_INTERVAL_MS
	ok = ok and ConstructionSequencer.clamp_tick_interval(9999) == ConstructionSequencer.MAX_TICK_INTERVAL_MS
	ok = ok and ConstructionSequencer.clamp_tick_interval(120) == 120
	ok = ok and ConstructionSequencer.clamp_tick_interval(null) == ConstructionSequencer.DEFAULT_TICK_INTERVAL_MS
	return _check("clamp_tick_interval: clamps to [10,500], defaults to 60 for null", ok)


# ── Sequence ─────────────────────────────────────────────────────────────────────────────────────

func _test_sequence_default_ordering_is_ring_by_ring() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks())
	var ok: bool = seq.ordering_mode == ConstructionSequencer.ORDER_RING_BY_RING
	ok = ok and seq.tick_interval_ms == ConstructionSequencer.DEFAULT_TICK_INTERVAL_MS
	return _check("Sequence: default ordering_mode=ring-by-ring, tick_interval_ms=60", ok)

func _test_sequence_advance_emits_one_per_interval() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks(), "ring-by-ring", 60)
	var e1 := seq.advance(60.0)
	var e2 := seq.advance(60.0)
	var ok: bool = e1.size() == 1 and e2.size() == 1
	ok = ok and int(e1[0]["index"]) == 0 and int(e2[0]["index"]) == 1
	return _check("Sequence.advance: exactly one event per full tick_interval_ms of elapsed time", ok)

func _test_sequence_advance_catches_up_multiple_due_chunks() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks(), "ring-by-ring", 50)
	var events := seq.advance(230.0)  # 4 full intervals due in one big jump
	var ok: bool = events.size() == 4
	for i in events.size():
		ok = ok and int(events[i]["index"]) == i
	return _check("Sequence.advance: a large delta_ms catches up ALL due chunks in one call (none skipped)", ok)

func _test_sequence_advance_never_exceeds_total() -> bool:
	var chunks: Array = [{"ring": 1, "arc": 0}, {"ring": 1, "arc": 1}]
	var seq := ConstructionSequencer.Sequence.new(chunks, "ring-by-ring", 10)
	var events := seq.advance(100000.0)  # absurdly large -- must stop at total(), never overrun
	var ok: bool = events.size() == 2 and seq.is_done()
	var more := seq.advance(1000.0)
	ok = ok and more.is_empty()
	return _check("Sequence.advance: stops exactly at total() even given a huge delta_ms; further advances emit nothing", ok)

func _test_sequence_is_done_and_progress() -> bool:
	var chunks: Array = [{"ring": 1, "arc": 0}, {"ring": 1, "arc": 1}]
	var seq := ConstructionSequencer.Sequence.new(chunks, "ring-by-ring", 10)
	var ok: bool = not seq.is_done() and seq.progress() == 0.0
	seq.advance(10.0)
	ok = ok and absf(seq.progress() - 0.5) < 1e-6 and not seq.is_done()
	seq.advance(10.0)
	ok = ok and seq.is_done() and seq.progress() == 1.0
	return _check("Sequence: is_done()/progress() track the cursor correctly through completion", ok)

func _test_sequence_last_event_flagged_is_last() -> bool:
	var chunks: Array = [{"ring": 1, "arc": 0}, {"ring": 1, "arc": 1}]
	var seq := ConstructionSequencer.Sequence.new(chunks, "ring-by-ring", 10)
	var events := seq.advance(20.0)
	var ok: bool = events.size() == 2
	ok = ok and events[0]["is_last"] == false and events[1]["is_last"] == true
	return _check("Sequence.advance: only the truly final emitted event carries is_last=true", ok)

func _test_sequence_carries_generation_id() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks(), "ring-by-ring", 10, 77)
	var events := seq.advance(10.0)
	var ok: bool = events.size() == 1 and int(events[0]["generation_id"]) == 77
	ok = ok and seq.generation_id == 77
	return _check("Sequence: caller-set generation_id is stamped on every emitted event", ok)

func _test_sequence_advance_batch_ignores_elapsed_time() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks(), "ring-by-ring", 1000)
	var events := seq.advance_batch(3)
	var ok: bool = events.size() == 3
	# A tiny subsequent advance() must NOT immediately fire (elapsed-time accumulator was reset by
	# the batch call, avoiding a double-catch-up burst).
	var next_events := seq.advance(1.0)
	ok = ok and next_events.is_empty()
	return _check("Sequence.advance_batch: force-emits N regardless of time, and resets the elapsed accumulator", ok)

func _test_sequence_reset_restarts_cursor() -> bool:
	var seq := ConstructionSequencer.Sequence.new(_sample_chunks(), "ring-by-ring", 10)
	seq.advance(30.0)
	var ok: bool = seq.cursor == 3
	seq.reset()
	ok = ok and seq.cursor == 0 and not seq.is_done()
	var events := seq.advance(10.0)
	ok = ok and events.size() == 1 and int(events[0]["index"]) == 0
	return _check("Sequence.reset: cursor + elapsed-time accumulator both restart from zero", ok)


# ── build() convenience ─────────────────────────────────────────────────────────────────────────

func _test_build_convenience_matches_manual_construction() -> bool:
	var chunks := _sample_chunks()
	var seq := ConstructionSequencer.build(chunks, {"ordering_mode": "radial-out", "tick_interval_ms": 25, "generation_id": 5})
	var manual_order := ConstructionSequencer.order_chunks(chunks, "radial-out")
	var ok: bool = seq.ordering_mode == "radial-out" and seq.tick_interval_ms == 25 and seq.generation_id == 5
	ok = ok and seq.total() == manual_order.size()
	for i in seq.total():
		ok = ok and seq.ordered[i]["ring"] == manual_order[i]["ring"] and seq.ordered[i]["arc"] == manual_order[i]["arc"]
	return _check("build(): tunables dict wiring matches manual Sequence construction + order_chunks", ok)


# ── direct composition with RingScaffoldGenerator (the actual upstream node) ─────────────────────

func _test_composes_with_real_ring_scaffold_wedge_chunks() -> bool:
	var topo := RingScaffoldGenerator.build_topology(3, RingScaffoldGenerator.DEFAULT_RADIUS_START,
		RingScaffoldGenerator.DEFAULT_GAP, RingScaffoldGenerator.DEFAULT_ELEVATION)
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 30.0, RingScaffoldGenerator.DEFAULT_GAP)
	var seq := ConstructionSequencer.build(chunks, {"ordering_mode": "ring-by-ring", "tick_interval_ms": 40})
	var ok: bool = seq.total() == chunks.size()
	var all_events: Array = []
	while not seq.is_done():
		all_events.append_array(seq.advance(40.0))
	ok = ok and all_events.size() == chunks.size()
	# ring-by-ring: the very first emitted chunk must be ring 1's arc 0.
	ok = ok and int(all_events[0]["chunk"]["ring"]) == 1 and int(all_events[0]["chunk"]["arc"]) == 0
	return _check("ConstructionSequencer composes directly with RingScaffoldGenerator.wedge_chunks() output", ok)
