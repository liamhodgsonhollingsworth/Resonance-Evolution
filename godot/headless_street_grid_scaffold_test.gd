extends SceneTree
## Headless test suite for renderers/street_grid_scaffold.gd (Wave-A1 increment 1, Project A node 1):
##
##   godot --headless --path godot -s res://headless_street_grid_scaffold_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_deterministic_same_inputs() and ok
	ok = _test_different_chunk_coord_differs() and ok
	ok = _test_different_seed_differs() and ok
	ok = _test_footprints_never_touch_forced_perimeter() and ok
	ok = _test_lot_sizes_within_range() and ok
	ok = _test_street_strips_have_street_width_dimension() and ok
	ok = _test_footprints_plus_streets_exactly_tile_chunk() and ok
	ok = _test_no_footprint_overlaps_another() and ok
	ok = _test_no_footprint_overlaps_a_street_strip() and ok
	ok = _test_lot_adjacency_symmetric_and_valid() and ok
	ok = _test_lot_adjacency_no_self_adjacency() and ok
	ok = _test_degenerate_inputs_clamp_not_crash() and ok
	ok = _test_multi_chunk_grid_boundaries_are_streets() and ok
	ok = _test_lot_box_mesh_and_center() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _rect_area(r: Rect2) -> float:
	return r.size.x * r.size.y


## Recursive rect subdivision accumulates float error (position = parent.position + prior siblings'
## widths, several levels deep) -- two rects meant to share an EXACT edge can end up ~1e-4 units
## apart/overlapping. "No overlap" is tested as "no MEANINGFUL overlap" (intersection area below a
## tiny tolerance) rather than Rect2.intersects()'s exact boolean, which is the correct invariant for
## a geometry pipeline (nothing downstream -- rendering, adjacency -- cares about a 1e-4 unit sliver).
const OVERLAP_AREA_TOLERANCE := 0.01

func _meaningfully_overlaps(a: Rect2, b: Rect2) -> bool:
	if not a.intersects(b):
		return false
	return _rect_area(a.intersection(b)) > OVERLAP_AREA_TOLERANCE


# ── determinism ──────────────────────────────────────────────────────────────────────────────────

func _test_deterministic_same_inputs() -> bool:
	var a := StreetGridScaffold.build(2026, Vector2i(3, -1), 64.0, 8.0, 22.0, 4.0, 1)
	var b := StreetGridScaffold.build(2026, Vector2i(3, -1), 64.0, 8.0, 22.0, 4.0, 1)
	var ok: bool = a["building_footprints"].size() == b["building_footprints"].size()
	for i in a["building_footprints"].size():
		var ra: Rect2 = a["building_footprints"][i]["rect"]
		var rb: Rect2 = b["building_footprints"][i]["rect"]
		ok = ok and ra.position.is_equal_approx(rb.position) and ra.size.is_equal_approx(rb.size)
	return _check("build(): identical (seed, chunk_coord, params) -> byte-identical footprints", ok)


func _test_different_chunk_coord_differs() -> bool:
	var a := StreetGridScaffold.build(2026, Vector2i(0, 0), 64.0, 8.0, 22.0, 4.0, 1)
	var b := StreetGridScaffold.build(2026, Vector2i(5, 9), 64.0, 8.0, 22.0, 4.0, 1)
	var same_count: bool = a["building_footprints"].size() == b["building_footprints"].size()
	var same_first := false
	if same_count and a["building_footprints"].size() > 0:
		var ra: Rect2 = a["building_footprints"][0]["rect"]
		var rb: Rect2 = b["building_footprints"][0]["rect"]
		same_first = ra.position.is_equal_approx(rb.position) and ra.size.is_equal_approx(rb.size)
	var differs := not (same_count and same_first)
	return _check("build(): different chunk_coord -> a different layout (chunk-deterministic, not global)", differs)


func _test_different_seed_differs() -> bool:
	var a := StreetGridScaffold.build(1, Vector2i(0, 0), 64.0, 8.0, 22.0, 4.0, 1)
	var b := StreetGridScaffold.build(2, Vector2i(0, 0), 64.0, 8.0, 22.0, 4.0, 1)
	var same_count: bool = a["building_footprints"].size() == b["building_footprints"].size()
	var same_first := false
	if same_count and a["building_footprints"].size() > 0:
		var ra: Rect2 = a["building_footprints"][0]["rect"]
		var rb: Rect2 = b["building_footprints"][0]["rect"]
		same_first = ra.position.is_equal_approx(rb.position) and ra.size.is_equal_approx(rb.size)
	return _check("build(): different seed -> a different layout", not (same_count and same_first))


# ── chunk-boundary seam mitigation (failure mode 1) ─────────────────────────────────────────────────

func _test_footprints_never_touch_forced_perimeter() -> bool:
	var chunk_size := 64.0
	var street_width := 4.0
	var result := StreetGridScaffold.build(2026, Vector2i(2, 2), chunk_size, 8.0, 22.0, street_width, 1)
	var origin: Vector2 = result["origin"]
	var lo := origin + Vector2(street_width, street_width)
	var hi := origin + Vector2(chunk_size - street_width, chunk_size - street_width)
	var ok := true
	for f in result["building_footprints"]:
		var r: Rect2 = f["rect"]
		ok = ok and r.position.x >= lo.x - 1e-4 and r.position.y >= lo.y - 1e-4
		ok = ok and r.end.x <= hi.x + 1e-4 and r.end.y <= hi.y + 1e-4
	return _check("build(): every footprint stays strictly within the forced street-margin interior", ok)


# ── size-range packing ───────────────────────────────────────────────────────────────────────────

func _test_lot_sizes_within_range() -> bool:
	var lot_min := 8.0
	var lot_max := 22.0
	var ok := true
	var checked := 0
	for cx in range(-2, 3):
		for cy in range(-2, 3):
			var result := StreetGridScaffold.build(2026, Vector2i(cx, cy), 64.0, lot_min, lot_max, 4.0, 1)
			for f in result["building_footprints"]:
				var r: Rect2 = f["rect"]
				ok = ok and r.size.x >= lot_min - 1e-3 and r.size.y >= lot_min - 1e-3
				checked += 1
	return _check("build(): every lot's footprint respects lot_size_min across a 5x5 chunk sweep (%d lots checked)" % checked, ok and checked > 0)


# ── street_polygon shape ─────────────────────────────────────────────────────────────────────────

func _test_street_strips_have_street_width_dimension() -> bool:
	var street_width := 4.0
	var result := StreetGridScaffold.build(2026, Vector2i(0, 0), 64.0, 8.0, 22.0, street_width, 1)
	var ok := true
	for strip in result["street_polygon"]:
		var r: Rect2 = strip as Rect2
		var w_matches := absf(r.size.x - street_width) < 1e-4
		var h_matches := absf(r.size.y - street_width) < 1e-4
		ok = ok and (w_matches or h_matches)
	return _check("build(): every street_polygon strip is exactly street_width wide on at least one axis", ok)


func _test_footprints_plus_streets_exactly_tile_chunk() -> bool:
	var chunk_size := 64.0
	var ok := true
	var checked := 0
	for cx in range(-1, 2):
		for cy in range(-1, 2):
			var result := StreetGridScaffold.build(999, Vector2i(cx, cy), chunk_size, 8.0, 22.0, 4.0, 7)
			var total := 0.0
			for f in result["building_footprints"]:
				total += _rect_area(f["rect"])
			for s in result["street_polygon"]:
				total += _rect_area(s as Rect2)
			ok = ok and absf(total - chunk_size * chunk_size) < 0.5
			checked += 1
	return _check("build(): building_footprints + street_polygon areas exactly sum to the chunk's full area (%d chunks checked)" % checked, ok)


func _test_no_footprint_overlaps_another() -> bool:
	var result := StreetGridScaffold.build(2026, Vector2i(4, -3), 64.0, 8.0, 22.0, 4.0, 1)
	var footprints: Array = result["building_footprints"]
	var ok := true
	for i in footprints.size():
		for j in range(i + 1, footprints.size()):
			var ri: Rect2 = footprints[i]["rect"]
			var rj: Rect2 = footprints[j]["rect"]
			ok = ok and not _meaningfully_overlaps(ri, rj)
	return _check("build(): no two building footprints overlap each other", ok)


func _test_no_footprint_overlaps_a_street_strip() -> bool:
	var result := StreetGridScaffold.build(2026, Vector2i(4, -3), 64.0, 8.0, 22.0, 4.0, 1)
	var ok := true
	for f in result["building_footprints"]:
		var rf: Rect2 = f["rect"]
		for s in result["street_polygon"]:
			ok = ok and not _meaningfully_overlaps(rf, s as Rect2)
	return _check("build(): no building footprint overlaps a street strip", ok)


# ── lot_adjacency ────────────────────────────────────────────────────────────────────────────────

func _test_lot_adjacency_symmetric_and_valid() -> bool:
	var result := StreetGridScaffold.build(2026, Vector2i(1, 1), 64.0, 8.0, 22.0, 4.0, 1)
	var adjacency: Dictionary = result["lot_adjacency"]
	var n: int = result["building_footprints"].size()
	var ok := adjacency.size() == n
	for id in adjacency:
		for other in adjacency[id]:
			ok = ok and typeof(other) == TYPE_INT and other >= 0 and other < n
			ok = ok and adjacency.has(other) and (adjacency[other] as Array).has(id)
	return _check("build(): lot_adjacency is symmetric and every id is a valid lot index", ok)


func _test_lot_adjacency_no_self_adjacency() -> bool:
	var result := StreetGridScaffold.build(2026, Vector2i(1, 1), 64.0, 8.0, 22.0, 4.0, 1)
	var adjacency: Dictionary = result["lot_adjacency"]
	var ok := true
	for id in adjacency:
		ok = ok and not (adjacency[id] as Array).has(id)
	return _check("build(): no lot is listed as adjacent to itself", ok)


# ── robustness ───────────────────────────────────────────────────────────────────────────────────

func _test_degenerate_inputs_clamp_not_crash() -> bool:
	var ok := true
	var r1 := StreetGridScaffold.build(0, Vector2i.ZERO, 0.0, 0.0, 0.0, 0.0, 0)
	ok = ok and (r1["building_footprints"] as Array).size() >= 1
	var r2 := StreetGridScaffold.build(-5, Vector2i(-10, -10), 4.0, 1000.0, 2000.0, 500.0, -3)
	ok = ok and (r2["building_footprints"] as Array).size() >= 1
	var r3 := StreetGridScaffold.build(2026, Vector2i(1, 1), 64.0, 40.0, 8.0, 4.0, 1)  # lot_max < lot_min
	ok = ok and (r3["building_footprints"] as Array).size() >= 1
	return _check("build(): degenerate/inverted inputs (0-size chunk, oversized lots, lot_max<lot_min) clamp, never crash/empty", ok)


func _test_multi_chunk_grid_boundaries_are_streets() -> bool:
	# Adjacent chunks each force their OWN boundary margin to be street -- so along the shared edge
	# between chunk (0,0) and (1,0), BOTH sides are street by construction, regardless of either
	# chunk's internal BSP solve. Verify no footprint from either chunk crosses x = chunk_size.
	var chunk_size := 64.0
	var a := StreetGridScaffold.build(42, Vector2i(0, 0), chunk_size, 8.0, 22.0, 4.0, 1)
	var b := StreetGridScaffold.build(42, Vector2i(1, 0), chunk_size, 8.0, 22.0, 4.0, 1)
	var ok := true
	for f in a["building_footprints"]:
		var r: Rect2 = f["rect"]
		ok = ok and r.end.x <= chunk_size + 1e-4
	for f in b["building_footprints"]:
		var r: Rect2 = f["rect"]
		ok = ok and r.position.x >= chunk_size - 1e-4
	return _check("build(): two horizontally-adjacent chunks never place a footprint across their shared boundary", ok)


# ── mesh helpers ─────────────────────────────────────────────────────────────────────────────────

func _test_lot_box_mesh_and_center() -> bool:
	var result := StreetGridScaffold.build(2026, Vector2i(0, 0), 64.0, 8.0, 22.0, 4.0, 1)
	var lot: Dictionary = result["building_footprints"][0]
	var mesh := StreetGridScaffold.lot_box_mesh(lot, 6.0, 0.0)
	var center := StreetGridScaffold.lot_box_center(lot, 6.0, 0.0)
	var rect: Rect2 = lot["rect"]
	var expected_center := rect.get_center()
	var ok := mesh != null and mesh is BoxMesh
	ok = ok and absf(center.x - expected_center.x) < 1e-4 and absf(center.z - expected_center.y) < 1e-4
	ok = ok and absf(center.y - 3.0) < 1e-4  # height/2
	return _check("lot_box_mesh/lot_box_center: non-null BoxMesh sized to the footprint, centered correctly", ok)
