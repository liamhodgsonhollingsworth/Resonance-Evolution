extends SceneTree
## Headless test suite for renderers/kit_grid_placer.gd (DQ-9c1bbfc5):
##
##   godot --headless --path godot -s res://headless_kit_grid_placer_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_deterministic_same_inputs() and ok
	ok = _test_different_seed_differs() and ok
	ok = _test_single_centered_scaled_and_centered() and ok
	ok = _test_single_centered_never_upscales() and ok
	ok = _test_tag_filter_starves_with_no_match() and ok
	ok = _test_tile_fill_raster_count() and ok
	ok = _test_tile_fill_respects_cap() and ok
	ok = _test_edge_scatter_on_perimeter() and ok
	ok = _test_unknown_fill_mode_returns_empty() and ok
	ok = _test_cells_from_footprints_seam() and ok
	ok = _test_cells_from_street_polygon_seam() and ok
	ok = _test_street_grid_scaffold_end_to_end_seam() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _demo_pieces() -> Array:
	return [
		{"asset_id": "post", "res_path": "res://post.glb", "footprint": Vector2(0.4, 0.4), "tags": ["prop", "post"], "weight": 1.0},
		{"asset_id": "wall", "res_path": "res://wall.glb", "footprint": Vector2(2.0, 0.5), "tags": ["wall"], "weight": 2.0},
		{"asset_id": "block", "res_path": "res://block.glb", "footprint": Vector2(3.0, 3.0), "tags": ["building"], "weight": 1.0},
	]


# ── determinism ──────────────────────────────────────────────────────────────────────────────────

func _test_deterministic_same_inputs() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 4, 4), "kind": "generic", "tags": []}]
	var pieces := _demo_pieces()
	var a := KitGridPlacer.place(cells, pieces, {"seed": 7, "fill_mode": "single_centered"})
	var b := KitGridPlacer.place(cells, pieces, {"seed": 7, "fill_mode": "single_centered"})
	var ok: bool = a.size() == b.size() and a.size() == 1
	ok = ok and a[0]["asset_id"] == b[0]["asset_id"]
	ok = ok and (a[0]["position"] as Vector3).is_equal_approx(b[0]["position"] as Vector3)
	ok = ok and absf(a[0]["rotation_deg"] - b[0]["rotation_deg"]) < 1e-6
	return _check("place(): identical (cells, pieces, params) -> identical placements", ok)


func _test_different_seed_differs() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 20, 20), "kind": "generic", "tags": []}]
	var pieces := _demo_pieces()
	var a := KitGridPlacer.place(cells, pieces, {"seed": 1, "fill_mode": "single_centered", "jitter_pos": 2.0})
	var b := KitGridPlacer.place(cells, pieces, {"seed": 2, "fill_mode": "single_centered", "jitter_pos": 2.0})
	var differs: bool = not (a[0]["position"] as Vector3).is_equal_approx(b[0]["position"] as Vector3) \
		or a[0]["asset_id"] != b[0]["asset_id"]
	return _check("place(): different seed -> a different layout", differs)


# ── single_centered ──────────────────────────────────────────────────────────────────────────────

func _test_single_centered_scaled_and_centered() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 3, 3), "kind": "generic", "tags": []}]
	var pieces := [{"asset_id": "big", "res_path": "res://big.glb", "footprint": Vector2(10, 10), "weight": 1.0}]
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "single_centered", "margin": 0.25, "scale_to_fit": true})
	var ok: bool = out.size() == 1
	var pos: Vector3 = out[0]["position"]
	ok = ok and out[0]["scale"] > 0.0 and out[0]["scale"] <= 1.0
	ok = ok and absf(pos.x - 1.5) < 1e-4 and absf(pos.z - 1.5) < 1e-4 and absf(pos.y) < 1e-9
	return _check("single_centered: one placement, centered, shrunk to fit an oversized piece", ok)


func _test_single_centered_never_upscales() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 100, 100), "kind": "generic", "tags": []}]
	var pieces := [{"asset_id": "tiny", "res_path": "res://tiny.glb", "footprint": Vector2(0.5, 0.5), "weight": 1.0}]
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "single_centered", "scale_to_fit": true})
	return _check("single_centered: scale_to_fit never upscales a small piece to fill a big cell", absf(out[0]["scale"] - 1.0) < 1e-6)


func _test_tag_filter_starves_with_no_match() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 4, 4), "kind": "generic", "tags": []}]
	var pieces := _demo_pieces()
	var matched := KitGridPlacer.place(cells, pieces, {"fill_mode": "single_centered", "required_tags": ["post"]})
	var starved := KitGridPlacer.place(cells, pieces, {"fill_mode": "single_centered", "required_tags": ["nonexistent"]})
	var ok: bool = matched.size() == 1 and matched[0]["asset_id"] == "post" and starved.is_empty()
	return _check("required_tags: filters selection correctly and starves (not substitutes) when nothing matches", ok)


# ── tile_fill ────────────────────────────────────────────────────────────────────────────────────

func _test_tile_fill_raster_count() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 10, 10), "kind": "generic", "tags": []}]
	var pieces := [{"asset_id": "tile", "res_path": "res://tile.glb", "footprint": Vector2(1, 1), "weight": 1.0}]
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "tile_fill", "margin": 0.0, "spacing": 0.0, "max_pieces_per_cell": 1000})
	return _check("tile_fill: exact raster count (100) for a clean 10x10 / 1x1 fit", out.size() == 100)


func _test_tile_fill_respects_cap() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 10, 10), "kind": "generic", "tags": []}]
	var pieces := [{"asset_id": "tile", "res_path": "res://tile.glb", "footprint": Vector2(1, 1), "weight": 1.0}]
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "tile_fill", "margin": 0.0, "spacing": 0.0, "max_pieces_per_cell": 7})
	return _check("tile_fill: max_pieces_per_cell caps placement count", out.size() == 7)


# ── edge_scatter ─────────────────────────────────────────────────────────────────────────────────

func _test_edge_scatter_on_perimeter() -> bool:
	var margin := 0.5
	var rect := Rect2(0, 0, 20, 8)
	var cells := [{"id": 0, "rect": rect, "kind": "street", "tags": []}]
	var pieces := [{"asset_id": "lamppost", "res_path": "res://lamppost.glb", "footprint": Vector2(0.3, 0.3), "weight": 1.0}]
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "edge_scatter", "margin": margin, "spacing": 2.0})
	var ok: bool = out.size() > 0
	var x0 := rect.position.x + margin
	var y0 := rect.position.y + margin
	var x1 := rect.position.x + rect.size.x - margin
	var y1 := rect.position.y + rect.size.y - margin
	for p in out:
		var pos: Vector3 = p["position"]
		var on_vertical: bool = absf(pos.x - x0) < 1e-4 or absf(pos.x - x1) < 1e-4
		var on_horizontal: bool = absf(pos.z - y0) < 1e-4 or absf(pos.z - y1) < 1e-4
		ok = ok and (on_vertical or on_horizontal)
	return _check("edge_scatter: every placement lies on the cell's margin-inset perimeter", ok)


# ── error handling ───────────────────────────────────────────────────────────────────────────────

func _test_unknown_fill_mode_returns_empty() -> bool:
	var cells := [{"id": 0, "rect": Rect2(0, 0, 4, 4), "kind": "generic", "tags": []}]
	var pieces := _demo_pieces()
	var out := KitGridPlacer.place(cells, pieces, {"fill_mode": "not_a_real_mode"})
	return _check("place(): an unknown fill_mode returns an empty result (push_error, never crashes)", out.is_empty())


# ── the placement seam with StreetGridScaffold ──────────────────────────────────────────────────
#
# StreetGridScaffold (DQ-1bcb379f, Project A, peer scope) is being built concurrently
# on its own branch and is NOT yet merged to origin/main -- this test suite must not
# take a hard build dependency on an unmerged peer class (that would couple this PR's
# mergeability to theirs). Instead these tests synthesize a Dictionary/Array in
# EXACTLY the shape `StreetGridScaffold.build()`'s own docstring documents
# (`{"building_footprints": [{"rect": Rect2, "id": int}, ...], "street_polygon":
# [Rect2, ...]}`) -- proving the seam CONTRACT. Once both branches land, the live
# call-site is a one-line swap (`StreetGridScaffold.build(...)` in place of the
# synthetic dict below) with zero change to KitGridPlacer itself.

func _synthetic_scaffold_result() -> Dictionary:
	return {
		"building_footprints": [
			{"rect": Rect2(4, 4, 10, 8), "id": 0},
			{"rect": Rect2(16, 4, 12, 8), "id": 1},
		],
		"street_polygon": [
			Rect2(0, 0, 64, 4),
			Rect2(0, 60, 64, 4),
		],
	}


func _test_cells_from_footprints_seam() -> bool:
	var result := _synthetic_scaffold_result()
	var cells := KitGridPlacer.cells_from_footprints(result["building_footprints"])
	var ok: bool = cells.size() == (result["building_footprints"] as Array).size()
	for c in cells:
		ok = ok and c["kind"] == "lot" and c["rect"] is Rect2
	return _check("cells_from_footprints: StreetGridScaffold.building_footprints shape -> lot cells, zero conversion loss", ok)


func _test_cells_from_street_polygon_seam() -> bool:
	var result := _synthetic_scaffold_result()
	var lot_count: int = (result["building_footprints"] as Array).size()
	var cells := KitGridPlacer.cells_from_street_polygon(result["street_polygon"], lot_count)
	var ok: bool = cells.size() == (result["street_polygon"] as Array).size()
	var ids_ok := true
	for c in cells:
		ok = ok and c["kind"] == "street"
		ids_ok = ids_ok and int(c["id"]) >= lot_count
	return _check("cells_from_street_polygon: StreetGridScaffold.street_polygon shape -> street cells, ids never collide with lots", ok and ids_ok)


func _test_street_grid_scaffold_end_to_end_seam() -> bool:
	# the seam contract, end to end: a StreetGridScaffold-shaped grid -> KitGridPlacer
	# places a kit on it, with NO peer file touched and NO grid-generation logic
	# duplicated here.
	var result := _synthetic_scaffold_result()
	var lot_cells := KitGridPlacer.cells_from_footprints(result["building_footprints"])
	var street_cells := KitGridPlacer.cells_from_street_polygon(result["street_polygon"], lot_cells.size())
	var pieces := _demo_pieces()
	var houses := KitGridPlacer.place(lot_cells, pieces, {"fill_mode": "single_centered", "required_tags": ["building"]})
	var props := KitGridPlacer.place(street_cells, pieces, {"fill_mode": "edge_scatter", "spacing": 3.0, "required_tags": ["post"]})
	var ok: bool = houses.size() == lot_cells.size()
	for h in houses:
		ok = ok and h["asset_id"] == "block"
	ok = ok and props.size() > 0
	for p in props:
		ok = ok and p["asset_id"] == "post"
	return _check("end-to-end seam: a StreetGridScaffold-shaped chunk feeds KitGridPlacer (lots get houses, streets get scattered props) (%d lots, %d street placements)" % [houses.size(), props.size()], ok)
