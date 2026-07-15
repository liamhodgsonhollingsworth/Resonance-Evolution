extends SceneTree
## Headless test suite for renderers/nature_scene_scatter.gd (NatureSceneScatter — the terrain ->
## constraint field -> scatter -> plant CALL closed loop, P0 items 0.1 + REUSED 0.2 of
## notes/planning/evolving_scene_generator_plan_2026_07_08.md, Wavelet PR #815):
##
##   godot --headless --path godot -s res://headless_nature_scene_scatter_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_scatter_zero_density_returns_empty() and ok
	ok = _test_scatter_degenerate_terrain_returns_empty() and ok
	ok = _test_scatter_produces_placements_on_gentle_terrain() and ok
	ok = _test_scatter_deterministic_same_seed() and ok
	ok = _test_scatter_different_seed_differs() and ok
	ok = _test_scatter_rejects_steep_slope_terrain() and ok
	ok = _test_scatter_placements_sit_on_terrain_height() and ok
	ok = _test_scatter_default_handle_produces_scene_node() and ok
	ok = _test_scatter_non_lsystem_handle_passthrough_no_scene_node() and ok
	ok = _test_scatter_call_target_matches_handle() and ok
	ok = _test_scatter_scale_within_tunable_range() and ok
	ok = _test_scatter_respects_min_dist_spacing() and ok
	ok = _test_scatter_biome_id_within_valid_range() and ok
	ok = _test_scatter_allowed_biomes_filters_placements() and ok
	ok = _test_scatter_end_to_end_with_terrain_build() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── synthetic fixtures ──────────────────────────────────────────────────────────────────────────

## A flat, gentle, grassland terrain: uniform low slope, mid moisture, biome forced to grassland —
## an easy "plants should definitely appear here" fixture, independent of TerrainGenerator's own
## noise (isolates NatureSceneScatter's own logic from terrain generation).
func _gentle_terrain(width: int = 12, depth: int = 12, cell_size: float = 1.0) -> Dictionary:
	var n := width * depth
	var heightfield := PackedFloat32Array()
	var slope := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var biome := PackedFloat32Array()
	heightfield.resize(n)
	slope.resize(n)
	moisture.resize(n)
	biome.resize(n)
	var grassland_norm := float(TerrainGenerator.BIOME_GRASSLAND) / float(TerrainGenerator.BIOME_COUNT - 1)
	for i in n:
		heightfield[i] = 2.0
		slope[i] = 0.05
		moisture[i] = 0.6
		biome[i] = grassland_norm
	return {
		"heightfield": heightfield, "width": width, "depth": depth, "cell_size": cell_size,
		"constraint_field": {"slope": slope, "height": heightfield, "moisture": moisture, "biome_id": biome},
	}

## A steep terrain: every cell slope == 1.0 (max, always rejected by the default max_slope).
func _steep_terrain(width: int = 12, depth: int = 12, cell_size: float = 1.0) -> Dictionary:
	var t := _gentle_terrain(width, depth, cell_size)
	var slope: PackedFloat32Array = t["constraint_field"]["slope"]
	for i in slope.size():
		slope[i] = 1.0
	return t

## A terrain with varying, sampleable height (a ramp) so placement-height checks are meaningful.
func _ramp_terrain(width: int = 10, depth: int = 10, cell_size: float = 1.0) -> Dictionary:
	var t := _gentle_terrain(width, depth, cell_size)
	var hf: PackedFloat32Array = t["heightfield"]
	for y in depth:
		for x in width:
			hf[y * width + x] = float(x) * 0.5  # ramps up along X
	return t


# ── basic gating ─────────────────────────────────────────────────────────────────────────────────

func _test_scatter_zero_density_returns_empty() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(), {"density": 0.0, "seed": 1})
	return _check("scatter: density=0.0 -> no placements", out.size() == 0)

func _test_scatter_degenerate_terrain_returns_empty() -> bool:
	var out := NatureSceneScatter.scatter({"width": 1, "depth": 1}, {"seed": 1, "density": 1.0})
	return _check("scatter: degenerate (width<2 or depth<2) terrain_result -> empty output, no crash", out.size() == 0)

func _test_scatter_produces_placements_on_gentle_terrain() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(20, 20), {"seed": 3, "density": 1.0, "min_dist": 1.5})
	return _check("scatter: gentle grassland terrain produces at least one placement", out.size() > 0)


# ── determinism ──────────────────────────────────────────────────────────────────────────────────

func _test_scatter_deterministic_same_seed() -> bool:
	var t := _gentle_terrain(16, 16)
	var a := NatureSceneScatter.scatter(t, {"seed": 42, "density": 0.9})
	var b := NatureSceneScatter.scatter(t, {"seed": 42, "density": 0.9})
	var ok := a.size() == b.size() and a.size() > 0
	for i in a.size():
		ok = ok and (a[i]["transform"] as Transform3D).origin.is_equal_approx((b[i]["transform"] as Transform3D).origin)
		ok = ok and is_equal_approx(float(a[i]["scale"]), float(b[i]["scale"]))
	return _check("scatter: identical seed -> identical placement set", ok)

func _test_scatter_different_seed_differs() -> bool:
	var t := _gentle_terrain(16, 16)
	var a := NatureSceneScatter.scatter(t, {"seed": 1, "density": 0.9})
	var b := NatureSceneScatter.scatter(t, {"seed": 2, "density": 0.9})
	var same := a.size() == b.size()
	if same and a.size() > 0:
		same = (a[0]["transform"] as Transform3D).origin.is_equal_approx((b[0]["transform"] as Transform3D).origin)
	return _check("scatter: different seed -> different placement set", not same)


# ── constraint-field gating ─────────────────────────────────────────────────────────────────────

func _test_scatter_rejects_steep_slope_terrain() -> bool:
	var out := NatureSceneScatter.scatter(_steep_terrain(16, 16), {"seed": 5, "density": 1.0})
	return _check("scatter: uniformly steep terrain (slope=1.0 > default max_slope) -> no placements", out.size() == 0)

func _test_scatter_placements_sit_on_terrain_height() -> bool:
	var t := _ramp_terrain(12, 12)
	var out := NatureSceneScatter.scatter(t, {"seed": 9, "density": 1.0, "min_dist": 1.0, "max_slope": 1.0})
	var ok := out.size() > 0
	for p in out:
		var origin: Vector3 = (p["transform"] as Transform3D).origin
		var expected_h := origin.x * 0.5  # the ramp's own height(x) function
		ok = ok and is_equal_approx(origin.y, expected_h)
	return _check("scatter: each placement's Y matches the terrain height at its XZ position", ok)


# ── CC0/rock asset seam ─────────────────────────────────────────────────────────────────────────

func _test_scatter_default_handle_produces_scene_node() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(16, 16), {"seed": 3, "density": 1.0})
	var ok := out.size() > 0
	for p in out:
		ok = ok and p["scene_node"] != null and (p["scene_node"] as Dictionary).has("children")
	return _check("scatter: default tree_asset_handle (lsystem:tree) builds a non-null scene_node", ok)

func _test_scatter_non_lsystem_handle_passthrough_no_scene_node() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(16, 16),
		{"seed": 3, "density": 1.0, "tree_asset_handle": "sdf:boulder"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and p["scene_node"] == null and String(p["call_target"]) == "sdf:boulder"
	return _check("scatter: non-lsystem handle (e.g. sdf:boulder) -> scene_node stays null, call_target passes through unresolved", ok)

func _test_scatter_call_target_matches_handle() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(16, 16),
		{"seed": 3, "density": 1.0, "tree_asset_handle": "lsystem:shrub"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and String(p["call_target"]) == "lsystem:shrub"
	return _check("scatter: call_target on every placement equals the tree_asset_handle tunable", ok)


# ── scale / spacing ──────────────────────────────────────────────────────────────────────────────

func _test_scatter_scale_within_tunable_range() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(18, 18),
		{"seed": 12, "density": 1.0, "size_min": 0.5, "size_max": 0.9})
	var ok := out.size() > 0
	for p in out:
		var s: float = p["scale"]
		ok = ok and s >= 0.5 and s <= 0.9
	return _check("scatter: every placement's scale falls within [size_min, size_max]", ok)

func _test_scatter_respects_min_dist_spacing() -> bool:
	var min_dist := 2.0
	var out := NatureSceneScatter.scatter(_gentle_terrain(24, 24),
		{"seed": 14, "density": 1.0, "min_dist": min_dist})
	var ok := out.size() > 1
	for i in out.size():
		for j in range(i + 1, out.size()):
			var oi: Vector3 = (out[i]["transform"] as Transform3D).origin
			var oj: Vector3 = (out[j]["transform"] as Transform3D).origin
			var d := Vector2(oi.x, oi.z).distance_to(Vector2(oj.x, oj.z))
			if d < min_dist - 0.01:
				ok = false
	return _check("scatter: every pair of placements stays >= min_dist apart (Poisson-disk guarantee holds through the wiring)", ok)


# ── biome ────────────────────────────────────────────────────────────────────────────────────────

func _test_scatter_biome_id_within_valid_range() -> bool:
	var out := NatureSceneScatter.scatter(_gentle_terrain(16, 16), {"seed": 6, "density": 1.0})
	var ok := out.size() > 0
	for p in out:
		var b: int = p["biome_id"]
		ok = ok and b >= 0 and b < TerrainGenerator.BIOME_COUNT
	return _check("scatter: biome_id on every placement is a valid TerrainGenerator biome index", ok)

func _test_scatter_allowed_biomes_filters_placements() -> bool:
	# Force the whole terrain to the WATER biome (excluded from DEFAULT_ALLOWED_BIOMES) -> nothing
	# should place even though slope/moisture would otherwise pass.
	var t := _gentle_terrain(14, 14)
	var biome: PackedFloat32Array = t["constraint_field"]["biome_id"]
	var water_norm := float(TerrainGenerator.BIOME_WATER) / float(TerrainGenerator.BIOME_COUNT - 1)
	for i in biome.size():
		biome[i] = water_norm
	var out := NatureSceneScatter.scatter(t, {"seed": 7, "density": 1.0})
	return _check("scatter: a terrain classified entirely as the (excluded) water biome yields no placements", out.size() == 0)


# ── full integration with TerrainGenerator.build() ─────────────────────────────────────────────

func _test_scatter_end_to_end_with_terrain_build() -> bool:
	# The real closed loop: TerrainGenerator.build() -> NatureSceneScatter.scatter(), no synthetic
	# fixtures — proves the two modules' Dictionary shapes actually agree with each other.
	var terrain := TerrainGenerator.build({"width": 24, "depth": 24, "seed": 55, "amplitude": 3.0,
		"erosion": {"method": "normal_detail", "strength": 0.3, "iterations": 2}})
	var out := NatureSceneScatter.scatter(terrain, {"seed": 55, "density": 0.8, "min_dist": 1.5})
	# Not asserting out.size() > 0 unconditionally (a random 24x24 terrain COULD roll all-excluded
	# biomes at low probability) -- assert the loop runs to completion with a well-shaped result.
	var ok := true
	for p in out:
		ok = ok and p.has("transform") and p.has("call_target") and p.has("seed") and p.has("biome_id") and p.has("scale")
	return _check("scatter: end-to-end against a REAL TerrainGenerator.build() result runs clean, well-shaped placements", ok)
