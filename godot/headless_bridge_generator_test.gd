extends SceneTree
## Headless test suite for renderers/bridge_generator.gd (BridgeGenerator, Wave 5 item 5.1 (B),
## DQ-225b57d9):
##
##   godot --headless --path godot -s res://headless_bridge_generator_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_generate_empty_input_returns_empty() and ok
	ok = _test_generate_zero_probability_returns_empty() and ok
	ok = _test_generate_same_ring_pair_never_bridged() and ok
	ok = _test_generate_different_ring_within_deltas_bridges() and ok
	ok = _test_generate_angle_delta_beyond_max_excluded() and ok
	ok = _test_generate_elevation_delta_beyond_max_excluded() and ok
	ok = _test_generate_pair_id_linked_cavities_never_bridged() and ok
	ok = _test_generate_deterministic_same_seed() and ok
	ok = _test_generate_invalid_ramp_style_falls_back_silently() and ok
	ok = _test_generate_mesh_non_null_and_nondegenerate() and ok
	ok = _test_generate_length_matches_origin_distance() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond

func _cavity(ring: int, x: float, y_elev: float, z: float, pair_id: String = "") -> Dictionary:
	return {
		"ring": ring, "elevation": y_elev, "pair_id": pair_id,
		"transform": Transform3D(Basis.IDENTITY, Vector3(x, y_elev, z)),
	}

func _test_generate_empty_input_returns_empty() -> bool:
	var out := BridgeGenerator.generate([], {"seed": 1})
	return _check("generate: empty cavity_instances -> empty output", out.size() == 0)

func _test_generate_zero_probability_returns_empty() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, 5.2, 0.0, 0.1)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 0.0, "seed": 1})
	return _check("generate: connect_probability=0.0 -> no bridges", out.size() == 0)

func _test_generate_same_ring_pair_never_bridged() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(1, 5.1, 0.0, 0.05)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 1})
	return _check("generate: two cavities on the SAME ring are never bridged", out.size() == 0)

func _test_generate_different_ring_within_deltas_bridges() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, 8.0, 0.5, 0.1)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 1})
	return _check("generate: different-ring pair within angle/elevation deltas + probability=1.0 -> bridged", out.size() == 1)

func _test_generate_angle_delta_beyond_max_excluded() -> bool:
	# a is at world angle 0 (pos x-axis); b is at world angle ~PI (neg x-axis) -- max angular separation.
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, -5.0, 0.0, 0.0)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": 0.1, "max_elevation_delta": 100.0, "seed": 1})
	return _check("generate: angle_delta beyond max_angle_delta excludes the pair", out.size() == 0)

func _test_generate_elevation_delta_beyond_max_excluded() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, 5.2, 50.0, 0.1)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 1.0, "seed": 1})
	return _check("generate: elevation_delta beyond max_elevation_delta excludes the pair", out.size() == 0)

func _test_generate_pair_id_linked_cavities_never_bridged() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0, "1_2_0"), _cavity(2, 5.2, 0.0, 0.1, "1_2_0")]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 1})
	return _check("generate: cavities already linked by a shared pair_id (through-passage) are never re-bridged", out.size() == 0)

func _test_generate_deterministic_same_seed() -> bool:
	var instances: Array = []
	for i in 6:
		instances.append(_cavity(1 + (i % 3), 5.0 + float(i), 0.1 * float(i), 0.2 * float(i)))
	var a := BridgeGenerator.generate(instances, {"connect_probability": 0.6, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 42})
	var b := BridgeGenerator.generate(instances, {"connect_probability": 0.6, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 42})
	return _check("generate: identical seed -> identical bridge count", a.size() == b.size())

func _test_generate_invalid_ramp_style_falls_back_silently() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, 5.2, 0.0, 0.1)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "ramp_style": "nonexistent_style", "seed": 1})
	var ok := out.size() == 1
	ok = ok and out[0]["mesh"] != null
	return _check("generate: unrecognized ramp_style falls back to 'simple' without crashing", ok)

func _test_generate_mesh_non_null_and_nondegenerate() -> bool:
	var instances: Array = [_cavity(1, 5.0, 0.0, 0.0), _cavity(2, 5.2, 1.0, 3.0)]
	var out := BridgeGenerator.generate(instances, {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 1})
	var ok := out.size() == 1
	if ok:
		var mesh: Mesh = out[0]["mesh"]
		ok = ok and mesh != null
		ok = ok and mesh.get_aabb().size.length() > 0.1
	return _check("generate: bridge mesh is non-null with a non-degenerate bounding box", ok)

func _test_generate_length_matches_origin_distance() -> bool:
	var a := _cavity(1, 0.0, 0.0, 0.0)
	var b := _cavity(2, 3.0, 0.0, 4.0)
	var out := BridgeGenerator.generate([a, b], {"connect_probability": 1.0, "max_angle_delta": TAU, "max_elevation_delta": 100.0, "seed": 1})
	var ok := out.size() == 1
	ok = ok and is_equal_approx(float(out[0]["length"]), 5.0)
	return _check("generate: reported length matches the straight-line distance between cavity origins", ok)
