extends SceneTree
## Headless test suite for renderers/dirt_floor_infill.gd (DirtFloorInfill, Wave 5 item 5.1 (B),
## DQ-225b57d9):
##
##   godot --headless --path godot -s res://headless_dirt_floor_infill_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_infill_empty_input_returns_empty() and ok
	ok = _test_infill_one_entry_per_input_cavity() and ok
	ok = _test_infill_mesh_non_null_nondegenerate() and ok
	ok = _test_infill_material_handle_default() and ok
	ok = _test_infill_material_handle_override() and ok
	ok = _test_infill_slope_matches_default_when_not_capped() and ok
	ok = _test_infill_slope_capped_for_extreme_request() and ok
	ok = _test_infill_ring_field_passthrough() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond

func _cavity(ring: int, size: float = 0.5) -> Dictionary:
	return {"ring": ring, "size": size, "transform": Transform3D(Basis.IDENTITY, Vector3(float(ring) * 3.0, 0.0, 1.0))}

func _test_infill_empty_input_returns_empty() -> bool:
	var out := DirtFloorInfill.infill([])
	return _check("infill: empty cavity_cutaway_field -> empty output", out.size() == 0)

func _test_infill_one_entry_per_input_cavity() -> bool:
	var cutaway: Array = [_cavity(1), _cavity(2), _cavity(3)]
	var out := DirtFloorInfill.infill(cutaway)
	return _check("infill: one dirt_patch_mesh entry per input cavity", out.size() == 3)

func _test_infill_mesh_non_null_nondegenerate() -> bool:
	var out := DirtFloorInfill.infill([_cavity(1)])
	var ok := out.size() == 1
	if ok:
		var mesh: Mesh = out[0]["mesh"]
		ok = ok and mesh != null and mesh.get_aabb().size.length() > 0.05
	return _check("infill: dirt patch mesh is non-null with a non-degenerate bounding box", ok)

func _test_infill_material_handle_default() -> bool:
	var out := DirtFloorInfill.infill([_cavity(1)])
	return _check("infill: material_handle defaults to DEFAULT_DIRT_MATERIAL_HANDLE",
		out.size() == 1 and String(out[0]["material_handle"]) == DirtFloorInfill.DEFAULT_DIRT_MATERIAL_HANDLE)

func _test_infill_material_handle_override() -> bool:
	var out := DirtFloorInfill.infill([_cavity(1)], {"dirt_material_handle": "rubble_scree"})
	return _check("infill: material_handle tunable overrides the default",
		out.size() == 1 and String(out[0]["material_handle"]) == "rubble_scree")

func _test_infill_slope_matches_default_when_not_capped() -> bool:
	var out := DirtFloorInfill.infill([_cavity(1, 0.5)], {"max_slope_deg": 30.0})
	var ok := out.size() == 1
	ok = ok and is_equal_approx(float(out[0]["slope_deg"]), 30.0)
	return _check("infill: reported slope_deg matches the requested max_slope_deg when not footprint-capped", ok)

func _test_infill_slope_capped_for_extreme_request() -> bool:
	var out := DirtFloorInfill.infill([_cavity(1, 1.0)], {"max_slope_deg": 89.0, "protrusion_fraction": 0.9})
	var ok := out.size() == 1
	ok = ok and float(out[0]["slope_deg"]) < 89.0
	return _check("infill: an extreme max_slope_deg request gets capped by the footprint bound", ok)

func _test_infill_ring_field_passthrough() -> bool:
	var out := DirtFloorInfill.infill([_cavity(7)])
	return _check("infill: ring field on the output matches the source cavity's ring",
		out.size() == 1 and int(out[0]["ring"]) == 7)
