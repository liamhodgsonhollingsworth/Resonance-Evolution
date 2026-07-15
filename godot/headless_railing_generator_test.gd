extends SceneTree
## Headless test suite for renderers/railing_generator.gd (RailingGenerator, DISPATCH claim
## underground-railing-iteration-2026-07-15):
##
##   godot --headless --path godot -s res://headless_railing_generator_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_generate_empty_path_returns_empty() and ok
	ok = _test_generate_single_point_returns_empty() and ok
	ok = _test_generate_straight_path_post_count() and ok
	ok = _test_generate_corner_forces_post_at_vertex() and ok
	ok = _test_generate_closed_loop_wraps_without_duplicate_seam() and ok
	ok = _test_generate_vertical_segment_path_normal_mode_no_crash() and ok
	ok = _test_generate_mesh_non_null_and_nondegenerate() and ok
	ok = _test_generate_vertical_bars_style_has_balusters() and ok
	ok = _test_generate_none_style_has_no_balusters() and ok
	ok = _test_generate_lattice_style_has_balusters() and ok
	ok = _test_generate_panel_style_mesh_nonnull() and ok
	ok = _test_generate_detail_scaling_reduces_baluster_count() and ok
	ok = _test_generate_length_matches_straight_line_distance() and ok
	ok = _test_generate_deterministic_same_input() and ok
	ok = _test_generate_zero_length_duplicate_points_skipped() and ok
	ok = _test_generate_for_bridge_returns_two_edges() and ok
	ok = _test_generate_for_bridge_missing_frame_returns_empty() and ok
	ok = _test_generate_for_cavity_rim_builds_chord() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond

func _test_generate_empty_path_returns_empty() -> bool:
	var out := RailingGenerator.generate([], {})
	return _check("generate: empty path -> empty result", out["mesh"] == null and out["post_count"] == 0)

func _test_generate_single_point_returns_empty() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0)], {})
	return _check("generate: single-point path -> empty result", out["mesh"] == null)

func _test_generate_straight_path_post_count() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(4, 0, 0)], {"post_spacing": 1.0})
	# 4m span / 1.0m spacing -> 4 segments -> 5 posts (0,1,2,3,4).
	return _check("generate: straight 4m path @ 1.0m spacing -> 5 posts", out["post_count"] == 5)

func _test_generate_corner_forces_post_at_vertex() -> bool:
	# A large spacing that would otherwise skip the corner if not forced.
	var path := [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 0, 10)]
	var out := RailingGenerator.generate(path, {"post_spacing": 50.0})
	# Forced posts at all 3 input vertices, regardless of the huge spacing.
	return _check("generate: corner vertex always gets a post regardless of spacing", out["post_count"] == 3)

func _test_generate_closed_loop_wraps_without_duplicate_seam() -> bool:
	var path := [Vector3(2, 0, 0), Vector3(0, 0, 2), Vector3(-2, 0, 0), Vector3(0, 0, -2)]
	var out := RailingGenerator.generate(path, {"post_spacing": 50.0, "closed": true})
	# 4 corners, closed loop, huge spacing -> exactly 4 posts (no duplicated seam point).
	return _check("generate: closed loop has exactly 4 posts, no duplicate seam", out["post_count"] == 4)

func _test_generate_vertical_segment_path_normal_mode_no_crash() -> bool:
	var path := [Vector3(0, 0, 0), Vector3(0, 5, 0)]
	var out := RailingGenerator.generate(path, {"up_vector_mode": "path_normal", "post_spacing": 1.0})
	return _check("generate: near-vertical path + path_normal mode does not crash, produces a mesh",
		out["mesh"] != null)

func _test_generate_mesh_non_null_and_nondegenerate() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 0)], {})
	var ok := out["mesh"] != null
	if ok:
		ok = (out["mesh"] as Mesh).get_aabb().size.length() > 0.1
	return _check("generate: mesh is non-null with a non-degenerate bounding box", ok)

func _test_generate_vertical_bars_style_has_balusters() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 0)],
		{"baluster_style": "vertical_bars", "baluster_spacing": 0.3})
	return _check("generate: vertical_bars style produces balusters", out["baluster_count"] > 0)

func _test_generate_none_style_has_no_balusters() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 0)], {"baluster_style": "none"})
	return _check("generate: 'none' style produces zero balusters (posts+rails only)",
		out["baluster_count"] == 0 and out["mesh"] != null)

func _test_generate_lattice_style_has_balusters() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 0)],
		{"baluster_style": "lattice", "baluster_spacing": 0.3})
	return _check("generate: lattice style produces balusters (diagonal pairs)", out["baluster_count"] > 0)

func _test_generate_panel_style_mesh_nonnull() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 0)], {"baluster_style": "panel"})
	return _check("generate: panel style produces a non-null mesh", out["mesh"] != null)

func _test_generate_detail_scaling_reduces_baluster_count() -> bool:
	var path := [Vector3(0, 0, 0), Vector3(6, 0, 0)]
	var full := RailingGenerator.generate(path, {"baluster_style": "vertical_bars", "baluster_spacing": 0.15, "detail": 1.0})
	var sparse := RailingGenerator.generate(path, {"baluster_style": "vertical_bars", "baluster_spacing": 0.15, "detail": 0.0})
	return _check("generate: detail=0.0 produces fewer (or equal) balusters than detail=1.0 (LOD)",
		sparse["baluster_count"] <= full["baluster_count"])

func _test_generate_length_matches_straight_line_distance() -> bool:
	var out := RailingGenerator.generate([Vector3(0, 0, 0), Vector3(3, 0, 4)], {"post_spacing": 50.0})
	return _check("generate: reported length matches straight-line distance",
		is_equal_approx(float(out["length"]), 5.0))

func _test_generate_deterministic_same_input() -> bool:
	var path := [Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(2, 0, 3)]
	var a := RailingGenerator.generate(path, {"baluster_style": "vertical_bars"})
	var b := RailingGenerator.generate(path, {"baluster_style": "vertical_bars"})
	return _check("generate: identical input -> identical post/baluster counts (no RNG)",
		a["post_count"] == b["post_count"] and a["baluster_count"] == b["baluster_count"])

func _test_generate_zero_length_duplicate_points_skipped() -> bool:
	var path := [Vector3(0, 0, 0), Vector3(0, 0, 0), Vector3(3, 0, 0)]
	var out := RailingGenerator.generate(path, {"post_spacing": 1.0})
	return _check("generate: duplicate consecutive points do not crash and still produce a mesh",
		out["mesh"] != null)

func _test_generate_for_bridge_returns_two_edges() -> bool:
	var bridge_entry := {
		"pa": Vector3(0, 0, 0), "pb": Vector3(4, 0, 0),
		"right": Vector3(0, 0, 1), "up": Vector3(0, 1, 0),
		"deck_width": 1.3, "deck_thickness": 0.2,
	}
	var out := RailingGenerator.generate_for_bridge(bridge_entry, {})
	var ok := out.size() == 2
	if ok:
		ok = out[0]["mesh"] != null and out[1]["mesh"] != null
	return _check("generate_for_bridge: returns exactly 2 non-null edge railings", ok)

func _test_generate_for_bridge_missing_frame_returns_empty() -> bool:
	var out := RailingGenerator.generate_for_bridge({"mesh": null}, {})
	return _check("generate_for_bridge: entry missing frame fields -> empty Array (no crash)", out.is_empty())

func _test_generate_for_cavity_rim_builds_chord() -> bool:
	var cavity := {
		"transform": Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)),
		"size": 0.8,
	}
	var out := RailingGenerator.generate_for_cavity_rim(cavity, {})
	return _check("generate_for_cavity_rim: produces a non-null chord railing mesh", out["mesh"] != null)
