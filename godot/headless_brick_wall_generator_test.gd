extends SceneTree
## Headless test suite for renderers/brick_wall_generator.gd:
##
##   godot --headless --path godot -s res://headless_brick_wall_generator_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails. Follows the SAME
## public-API-only testing convention as headless_brick_pavement_generator_test.gd (exercise
## BrickWallGenerator.build()/wall_multimeshes() only, no reaching into private helpers).

const RUNNING := "res://assets/wall_exemplars/running_bond_wall.json"
const COMMON := "res://assets/wall_exemplars/common_bond_wall.json"
const FLEMISH := "res://assets/wall_exemplars/flemish_bond_wall.json"
const STACK_TSCN := "res://assets/wall_exemplars/stack_bond_wall_exemplar.tscn"

const ORIENT_STRETCHER := 0
const ORIENT_HEADER := 90
const ORIENT_QUOIN_LONG_X := 400
const ORIENT_QUOIN_LONG_Z := 401

func _initialize() -> void:
	var ok := true
	ok = _test_default_build_produces_stretcher_group() and ok
	ok = _test_running_bond_default_has_no_header_group() and ok
	ok = _test_common_bond_has_header_group() and ok
	ok = _test_flemish_bond_has_both_header_and_stretcher() and ok
	ok = _test_tscn_backend_loads_and_dedupes() and ok
	ok = _test_default_openings_include_door_and_window() and ok
	ok = _test_ground_floor_door_false_has_no_door() and ok
	ok = _test_mortar_gap_shrinks_mesh() and ok
	ok = _test_degenerate_inputs_clamp_not_crash() and ok
	ok = _test_deterministic_same_inputs() and ok
	ok = _test_larger_footprint_more_bricks() and ok
	ok = _test_wall_multimeshes_match_groups() and ok
	ok = _test_header_width_is_half_brick_length() and ok
	ok = _test_quoin_corners_present_and_alternate() and ok
	ok = _test_field_coursing_has_no_corner_gap() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _default_footprint() -> Rect2:
	return Rect2(0.0, 0.0, 8.0, 6.0)


func _total_bricks(result: Dictionary) -> int:
	var total := 0
	for g in (result["brick_groups"] as Array):
		total += (g["transforms"] as Array).size()
	return total


func _has_orientation(result: Dictionary, orient: int) -> bool:
	for g in (result["brick_groups"] as Array):
		if int(g["orientation"]) == orient:
			return not (g["transforms"] as Array).is_empty()
	return false


func _test_default_build_produces_stretcher_group() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {})
	var ok := _has_orientation(result, ORIENT_STRETCHER)
	ok = ok and _total_bricks(result) > 0
	return _check("build(): default params produce a non-empty stretcher field-coursing group", ok)


func _test_running_bond_default_has_no_header_group() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed_handle": RUNNING})
	var ok := not _has_orientation(result, ORIENT_HEADER)
	return _check("build(): running-bond seed (default) produces zero header-course bricks", ok)


func _test_common_bond_has_header_group() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed_handle": COMMON})
	var ok := _has_orientation(result, ORIENT_HEADER)
	return _check("build(): common-bond seed produces a real header-course group", ok)


func _test_flemish_bond_has_both_header_and_stretcher() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed_handle": FLEMISH})
	var ok := _has_orientation(result, ORIENT_HEADER) and _has_orientation(result, ORIENT_STRETCHER)
	return _check("build(): Flemish-bond seed mixes header AND stretcher every course", ok)


func _test_tscn_backend_loads_and_dedupes() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 2.0, {"seed_handle": STACK_TSCN})
	var stretcher_transforms: Array = []
	for g in (result["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_STRETCHER:
			stretcher_transforms = g["transforms"]
	var ok := stretcher_transforms.size() > 0
	# dedup check: no two transforms share a (near-)identical origin
	var seen: Dictionary = {}
	var dup_found := false
	for t in stretcher_transforms:
		var tr: Transform3D = t
		var key := "%d_%d_%d" % [int(round(tr.origin.x * 1000.0)), int(round(tr.origin.y * 1000.0)), int(round(tr.origin.z * 1000.0))]
		if seen.has(key):
			dup_found = true
		seen[key] = true
	ok = ok and not dup_found
	return _check("build(): .tscn (bbox-inferred) backend loads AND produces deduped, non-overlapping placements (n=%d)" % stretcher_transforms.size(), ok)


func _test_default_openings_include_door_and_window() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 6.0, {"row_count": 3, "ground_floor_door": true})
	var has_door := false
	var has_window := false
	for o in (result["openings"] as Array):
		if o["type"] == "door":
			has_door = true
		if o["type"] == "window":
			has_window = true
	return _check("build(): default layout produces BOTH a ground-floor door and window openings", has_door and has_window)


func _test_ground_floor_door_false_has_no_door() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 6.0, {"ground_floor_door": false})
	var has_door := false
	for o in (result["openings"] as Array):
		if o["type"] == "door":
			has_door = true
	return _check("build(): ground_floor_door=false produces zero door openings", not has_door)


func _test_mortar_gap_shrinks_mesh() -> bool:
	var narrow := BrickWallGenerator.build(_default_footprint(), 3.0, {"mortar_gap": 0.001})
	var wide := BrickWallGenerator.build(_default_footprint(), 3.0, {"mortar_gap": 0.02})
	var narrow_mesh: BoxMesh = null
	var wide_mesh: BoxMesh = null
	for g in (narrow["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_STRETCHER:
			narrow_mesh = g["mesh"]
	for g in (wide["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_STRETCHER:
			wide_mesh = g["mesh"]
	var ok := narrow_mesh != null and wide_mesh != null and narrow_mesh.size.x > wide_mesh.size.x
	return _check("build(): a larger mortar_gap shrinks the stretcher brick mesh (joint reveal)", ok)


func _test_degenerate_inputs_clamp_not_crash() -> bool:
	var ok := true
	var r1 := BrickWallGenerator.build(Rect2(0, 0, 0, 0), 0.0, {})
	ok = ok and r1.has("brick_groups") and r1.has("openings")
	var r2 := BrickWallGenerator.build(Rect2(0, 0, 0.01, 0.01), -5.0, {})
	ok = ok and r2.has("brick_groups")
	var r3 := BrickWallGenerator.build(_default_footprint(), 3.0, {"mortar_gap": -5.0, "row_count": -1, "window_width": -1.0, "window_spacing": -1.0})
	ok = ok and r3.has("brick_groups")
	return _check("build(): degenerate/negative inputs (zero-size rect, negative height/params) clamp, never crash", ok)


func _test_deterministic_same_inputs() -> bool:
	var a := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed": 2026})
	var b := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed": 2026})
	var ok := _total_bricks(a) == _total_bricks(b) and _total_bricks(a) > 0
	return _check("build(): identical (footprint, height, params) -> identical brick count", ok)


func _test_larger_footprint_more_bricks() -> bool:
	var small := BrickWallGenerator.build(Rect2(0, 0, 6.0, 5.0), 3.0, {})
	var big := BrickWallGenerator.build(Rect2(0, 0, 20.0, 16.0), 3.0, {})
	var ok := _total_bricks(big) > _total_bricks(small)
	return _check("build(): a larger footprint produces strictly more field-coursing bricks", ok)


func _test_wall_multimeshes_match_groups() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed_handle": COMMON})
	var mmis := BrickWallGenerator.wall_multimeshes(result)
	var ok := mmis.size() == (result["brick_groups"] as Array).size() and mmis.size() > 0
	for i in mmis.size():
		var mmi: MultiMeshInstance3D = mmis[i]
		var group: Dictionary = result["brick_groups"][i]
		ok = ok and mmi.multimesh.instance_count == (group["transforms"] as Array).size()
	return _check("wall_multimeshes(): one MultiMeshInstance3D per orientation group, instance counts match", ok)


func _test_header_width_is_half_brick_length() -> bool:
	# indirect check: a common-bond header brick's world-space AABB along its wall's tangent axis
	# should be ~half the stretcher's -- confirms the derived header_width = brick_length/2 invariant
	# actually reaches the render (not just documented).
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {"seed_handle": COMMON, "mortar_gap": 0.0})
	var stretcher_len := -1.0
	var header_len := -1.0
	for g in (result["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_STRETCHER:
			stretcher_len = (g["mesh"] as BoxMesh).size.x
		elif int(g["orientation"]) == ORIENT_HEADER:
			header_len = (g["mesh"] as BoxMesh).size.x
	var ok := stretcher_len > 0.0 and header_len > 0.0 and absf(header_len - stretcher_len * 0.5) < 1e-4
	return _check("build(): header exposed width is exactly half the stretcher length (real 2:1 ratio, header_len=%.4f stretcher_len=%.4f)" % [header_len, stretcher_len], ok)


func _test_quoin_corners_present_and_alternate() -> bool:
	var result := BrickWallGenerator.build(_default_footprint(), 3.0, {})
	var has_x := false
	var has_z := false
	for g in (result["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_QUOIN_LONG_X and not (g["transforms"] as Array).is_empty():
			has_x = true
		if int(g["orientation"]) == ORIENT_QUOIN_LONG_Z and not (g["transforms"] as Array).is_empty():
			has_z = true
	return _check("build(): additive quoin corner posts present with BOTH long-X and long-Z blocks (per-course alternation)", has_x and has_z)


## Regression test for a real defect found by an actual --milestone-shot render (adversarial
## iteration, not just code review): an EARLIER exclusion-based corner-toothing design left a
## full-height gap because two independent per-wall coursing loops in perpendicular planes don't
## close a hole left in one wall's own plane. Field coursing must now reach flush to every corner.
func _test_field_coursing_has_no_corner_gap() -> bool:
	var footprint := _default_footprint()
	var result := BrickWallGenerator.build(footprint, 3.0, {})
	var corners: Array = [footprint.position, footprint.position + Vector2(footprint.size.x, 0.0),
		footprint.position + footprint.size, footprint.position + Vector2(0.0, footprint.size.y)]
	var field_positions: Array = []
	for g in (result["brick_groups"] as Array):
		if int(g["orientation"]) == ORIENT_STRETCHER or int(g["orientation"]) == ORIENT_HEADER:
			for t in (g["transforms"] as Array):
				field_positions.append((t as Transform3D).origin)
	var ok := true
	for c_v in corners:
		var c: Vector2 = c_v
		var found := false
		for p_v in field_positions:
			var p: Vector3 = p_v
			if Vector2(p.x, p.z).distance_to(c) < 0.25:
				found = true
				break
		ok = ok and found
	return _check("build(): field coursing reaches within 0.25m of all 4 building corners (no exclusion gap)", ok)
