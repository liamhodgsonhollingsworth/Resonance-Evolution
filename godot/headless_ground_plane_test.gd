extends SceneTree
## Headless test suite for renderers/ground_plane.gd (GroundPlane, DISPATCH claim
## underground-railing-iteration-2026-07-15):
##
##   godot --headless --path godot -s res://headless_ground_plane_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_build_mesh_nonnull() and ok
	ok = _test_build_mesh_default_at_origin() and ok
	ok = _test_build_mesh_position_sits_below_elevation() and ok
	ok = _test_build_mesh_size_scales_extent() and ok
	ok = _test_build_mesh_clamps_degenerate_size() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond

func _test_build_mesh_nonnull() -> bool:
	var result: Dictionary = GroundPlane.build_mesh({})
	return _check("build_mesh: default tunables -> non-null mesh", result["mesh"] != null)

func _test_build_mesh_default_at_origin() -> bool:
	var result: Dictionary = GroundPlane.build_mesh({})
	var pos: Vector3 = result["position"]
	return _check("build_mesh: default elevation -> plane sits at/just below Y=0",
		pos.y <= 0.0 and pos.y > -1.0)

func _test_build_mesh_position_sits_below_elevation() -> bool:
	var result: Dictionary = GroundPlane.build_mesh({"elevation": 5.0, "thickness": 0.2})
	var pos: Vector3 = result["position"]
	return _check("build_mesh: plane's own top surface sits exactly at the requested elevation",
		is_equal_approx(pos.y + 0.1, 5.0))

func _test_build_mesh_size_scales_extent() -> bool:
	var small: Dictionary = GroundPlane.build_mesh({"size": 5.0})
	var large: Dictionary = GroundPlane.build_mesh({"size": 50.0})
	var small_aabb: AABB = (small["mesh"] as Mesh).get_aabb()
	var large_aabb: AABB = (large["mesh"] as Mesh).get_aabb()
	return _check("build_mesh: larger size tunable -> larger mesh extent",
		large_aabb.size.x > small_aabb.size.x)

func _test_build_mesh_clamps_degenerate_size() -> bool:
	var result: Dictionary = GroundPlane.build_mesh({"size": -5.0, "thickness": -1.0})
	return _check("build_mesh: negative/degenerate tunables clamp, never crash", result["mesh"] != null)
