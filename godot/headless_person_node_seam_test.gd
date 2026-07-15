extends SceneTree
## Headless test suite for renderers/person_node_seam.gd (PersonNodeSeam, Wave 5 item 5.1 (B),
## DQ-225b57d9):
##
##   godot --headless --path godot -s res://headless_person_node_seam_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_place_real_photo_cutout_is_blocked() and ok
	ok = _test_place_silhouette_default_nonempty() and ok
	ok = _test_place_zero_density_returns_empty_not_blocked() and ok
	ok = _test_place_evolved_character_scene_node_null() and ok
	ok = _test_place_silhouette_scene_node_nonnull() and ok
	ok = _test_place_unrecognized_mode_falls_back_to_silhouette() and ok
	ok = _test_place_deterministic_same_seed() and ok
	ok = _test_place_different_seed_differs() and ok
	ok = _test_place_elevation_matches_ring() and ok
	ok = _test_place_radius_matches_ring() and ok
	ok = _test_place_multiple_rings_represented() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond

func _ring(ring: int, radius: float, elevation: float) -> Dictionary:
	return {"ring": ring, "radius": radius, "elevation": elevation}

func _topo() -> Array:
	return [_ring(1, 9.0, 0.0), _ring(2, 15.0, -0.2), _ring(3, 21.0, -0.4)]

func _test_place_real_photo_cutout_is_blocked() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"mode": "real_photo_cutout"})
	var ok := bool(result["blocked"]) == true
	ok = ok and (result["person_placements"] as Array).size() == 0
	ok = ok and String(result["reason"]).length() > 0
	return _check("place: real_photo_cutout mode is BLOCKED (empty placements + a reason, never silently built)", ok)

func _test_place_silhouette_default_nonempty() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"density": 0.8, "walk_path_seed": 5})
	var placements: Array = result["person_placements"]
	return _check("place: default (silhouette) mode with density>0 -> non-empty placements", placements.size() > 0)

func _test_place_zero_density_returns_empty_not_blocked() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"density": 0.0})
	var ok := bool(result["blocked"]) == false
	ok = ok and (result["person_placements"] as Array).size() == 0
	return _check("place: density=0.0 -> empty placements, NOT flagged blocked (blocked is real_photo_cutout-only)", ok)

func _test_place_evolved_character_scene_node_null() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"mode": "evolved_character", "density": 1.0, "walk_path_seed": 3})
	var placements: Array = result["person_placements"]
	var ok := placements.size() > 0
	for p in placements:
		ok = ok and p["scene_node"] == null and String(p["call_target"]) == "evolved_character:default"
	return _check("place: evolved_character mode -> scene_node stays null, call_target passes through (stub seam, not built)", ok)

func _test_place_silhouette_scene_node_nonnull() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"mode": "silhouette", "density": 1.0, "walk_path_seed": 3})
	var placements: Array = result["person_placements"]
	var ok := placements.size() > 0
	for p in placements:
		ok = ok and p["scene_node"] != null and (p["scene_node"] as Dictionary).get("mesh", {}).get("shape", "") == "box"
	return _check("place: silhouette mode builds a non-null box-primitive scene_node", ok)

func _test_place_unrecognized_mode_falls_back_to_silhouette() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"mode": "not_a_real_mode", "density": 1.0, "walk_path_seed": 3})
	var placements: Array = result["person_placements"]
	var ok := placements.size() > 0
	for p in placements:
		ok = ok and String(p["mode"]) == PersonNodeSeam.MODE_SILHOUETTE and p["scene_node"] != null
	return _check("place: unrecognized mode string falls back to silhouette (not a silent empty result)", ok)

func _test_place_deterministic_same_seed() -> bool:
	var a := PersonNodeSeam.place(_topo(), {"density": 0.5, "walk_path_seed": 77})
	var b := PersonNodeSeam.place(_topo(), {"density": 0.5, "walk_path_seed": 77})
	var pa: Array = a["person_placements"]
	var pb: Array = b["person_placements"]
	var ok := pa.size() == pb.size() and pa.size() > 0
	for i in pa.size():
		ok = ok and (pa[i]["transform"] as Transform3D).origin.is_equal_approx((pb[i]["transform"] as Transform3D).origin)
	return _check("place: identical walk_path_seed -> identical placement set", ok)

func _test_place_different_seed_differs() -> bool:
	var a := PersonNodeSeam.place(_topo(), {"density": 0.5, "walk_path_seed": 1})
	var b := PersonNodeSeam.place(_topo(), {"density": 0.5, "walk_path_seed": 2})
	var pa: Array = a["person_placements"]
	var pb: Array = b["person_placements"]
	var same := pa.size() == pb.size()
	if same and pa.size() > 0:
		same = (pa[0]["transform"] as Transform3D).origin.is_equal_approx((pb[0]["transform"] as Transform3D).origin)
	return _check("place: different walk_path_seed produces a different placement set", not same)

func _test_place_elevation_matches_ring() -> bool:
	var result := PersonNodeSeam.place([_ring(9, 12.0, -3.5)], {"density": 1.0, "walk_path_seed": 8})
	var placements: Array = result["person_placements"]
	var ok := placements.size() > 0
	for p in placements:
		ok = ok and is_equal_approx((p["transform"] as Transform3D).origin.y, -3.5)
	return _check("place: every placement's world Y matches its ring's own elevation (floor level)", ok)

func _test_place_radius_matches_ring() -> bool:
	var result := PersonNodeSeam.place([_ring(4, 10.0, 0.0)], {"density": 1.0, "walk_path_seed": 9})
	var placements: Array = result["person_placements"]
	var ok := placements.size() > 0
	for p in placements:
		var origin: Vector3 = (p["transform"] as Transform3D).origin
		var r := Vector2(origin.x, origin.z).length()
		ok = ok and is_equal_approx(r, 10.0)
	return _check("place: every placement sits exactly on its ring's own centerline radius (jitter is angular only)", ok)

func _test_place_multiple_rings_represented() -> bool:
	var result := PersonNodeSeam.place(_topo(), {"density": 1.0, "walk_path_seed": 11})
	var placements: Array = result["person_placements"]
	var rings := {}
	for p in placements:
		rings[int(p["ring"])] = true
	return _check("place: placements are drawn from every ring in ring_topology", rings.size() == 3)
