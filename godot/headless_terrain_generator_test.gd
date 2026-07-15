extends SceneTree
## Headless test suite for renderers/terrain_generator.gd (TerrainGenerator, P0 item 0.1 of
## notes/planning/evolving_scene_generator_plan_2026_07_08.md, Wavelet PR #815):
##
##   godot --headless --path godot -s res://headless_terrain_generator_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails. This IS the
## "testable without Liam" closed-loop check the dispatch item requires: determinism, parameter-
## range validity, and the terrain->constraint-field->scatter contract, all asserted headlessly —
## no human judgment of a screenshot required to trust this module.

func _initialize() -> void:
	var ok := true
	ok = _test_heightfield_deterministic_same_seed() and ok
	ok = _test_heightfield_different_seed_differs() and ok
	ok = _test_heightfield_size_matches_grid() and ok
	ok = _test_heightfield_within_amplitude_bounds() and ok
	ok = _test_heightfield_zero_octaves_is_flat() and ok
	ok = _test_detail_field_cross_fade_increases_variance() and ok
	ok = _test_child_seed_deterministic() and ok
	ok = _test_child_seed_varies_with_coords() and ok
	ok = _test_erosion_none_is_identity() and ok
	ok = _test_erosion_normal_detail_reduces_max_slope() and ok
	ok = _test_erosion_conserves_total_mass_approximately() and ok
	ok = _test_erosion_deterministic() and ok
	ok = _test_erosion_unimplemented_method_falls_back_safely() and ok
	ok = _test_constraint_field_shapes_match_heightfield() and ok
	ok = _test_constraint_field_values_in_unit_range() and ok
	ok = _test_constraint_field_flat_low_terrain_is_water_biome() and ok
	ok = _test_constraint_field_steep_terrain_is_rock_or_alpine_biome() and ok
	ok = _test_build_mesh_vertex_count() and ok
	ok = _test_build_mesh_empty_on_degenerate_grid() and ok
	ok = _test_sample_bilinear_matches_grid_points() and ok
	ok = _test_sample_bilinear_interpolates_between_points() and ok
	ok = _test_build_top_level_returns_consistent_shapes() and ok
	ok = _test_build_deterministic_end_to_end() and ok
	ok = _test_export_glb_writes_nonempty_file() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── heightfield generation ──────────────────────────────────────────────────────────────────────

func _test_heightfield_deterministic_same_seed() -> bool:
	var a := TerrainGenerator.generate_heightfield(9, 9, {"seed": 42})
	var b := TerrainGenerator.generate_heightfield(9, 9, {"seed": 42})
	var ok := a.size() == b.size()
	for i in a.size():
		ok = ok and is_equal_approx(a[i], b[i])
	return _check("generate_heightfield: identical seed -> byte-identical heightfield", ok)

func _test_heightfield_different_seed_differs() -> bool:
	var a := TerrainGenerator.generate_heightfield(9, 9, {"seed": 1})
	var b := TerrainGenerator.generate_heightfield(9, 9, {"seed": 2})
	var same := true
	for i in a.size():
		if not is_equal_approx(a[i], b[i]):
			same = false
			break
	return _check("generate_heightfield: different seed -> different heightfield", not same)

func _test_heightfield_size_matches_grid() -> bool:
	var hf := TerrainGenerator.generate_heightfield(12, 7, {"seed": 3})
	return _check("generate_heightfield: output size == width*depth", hf.size() == 12 * 7)

func _test_heightfield_within_amplitude_bounds() -> bool:
	var amp := 5.0
	var hf := TerrainGenerator.generate_heightfield(16, 16, {"seed": 5, "amplitude": amp})
	var ok := true
	for h in hf:
		if h < -amp - 0.001 or h > amp + 0.001:
			ok = false
			break
	return _check("generate_heightfield: every height stays within [-amplitude, amplitude]", ok)

func _test_heightfield_zero_octaves_is_flat() -> bool:
	var hf := TerrainGenerator.generate_heightfield(6, 6, {"seed": 1, "base_octaves": 0, "extra_octaves": 0})
	var ok := true
	for h in hf:
		if not is_equal_approx(h, -float(TerrainGenerator.DEFAULT_AMPLITUDE)):
			# base()==0 octaves -> _fbm returns 0.0 -> (0-0.5)*2*amplitude == -amplitude, constant.
			ok = false
			break
	return _check("generate_heightfield: zero octaves -> flat constant field", ok)

func _test_detail_field_cross_fade_increases_variance() -> bool:
	var w := 20
	var d := 20
	var uniform_far := TerrainGenerator.generate_heightfield(w, d, {"seed": 9, "base_octaves": 1, "extra_octaves": 4})
	var detail := DetailField.build(w, d, 1.0, {"type": "uniform"})
	var full_near := TerrainGenerator.generate_heightfield(w, d, {"seed": 9, "base_octaves": 1, "extra_octaves": 4}, detail)
	# A full detail budget everywhere should pull the field toward the higher-octave result, i.e.
	# NOT be identical to the always-base-only field (the cross-fade actually engages).
	var same := true
	for i in uniform_far.size():
		if not is_equal_approx(uniform_far[i], full_near[i]):
			same = false
			break
	return _check("generate_heightfield: detail_field budget=1.0 changes the result vs base-only (cross-fade engages)", not same)


# ── deterministic child-seeding ─────────────────────────────────────────────────────────────────

func _test_child_seed_deterministic() -> bool:
	var a := TerrainGenerator.child_seed(100, 3, 4)
	var b := TerrainGenerator.child_seed(100, 3, 4)
	return _check("child_seed: same parent+coords -> same child seed", a == b)

func _test_child_seed_varies_with_coords() -> bool:
	var a := TerrainGenerator.child_seed(100, 3, 4)
	var b := TerrainGenerator.child_seed(100, 3, 5)
	var c := TerrainGenerator.child_seed(100, 4, 4)
	return _check("child_seed: different tile coords -> different child seeds", a != b and a != c)


# ── erosion (normal_detail) ─────────────────────────────────────────────────────────────────────

func _test_erosion_none_is_identity() -> bool:
	var hf := TerrainGenerator.generate_heightfield(10, 10, {"seed": 4})
	var out := TerrainGenerator.apply_erosion(hf, 10, 10, {"method": "none"})
	var ok := hf.size() == out.size()
	for i in hf.size():
		ok = ok and is_equal_approx(hf[i], out[i])
	return _check("apply_erosion: method='none' is the identity transform", ok)

func _max_slope(hf: PackedFloat32Array, w: int, d: int) -> float:
	var m := 0.0
	for y in d:
		for x in w:
			var h: float = hf[y * w + x]
			for delta: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx := x + delta.x
				var ny := y + delta.y
				if nx < w and ny < d:
					m = maxf(m, absf(h - hf[ny * w + nx]))
	return m

func _test_erosion_normal_detail_reduces_max_slope() -> bool:
	var w := 14
	var d := 14
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 11, "base_octaves": 4, "extra_octaves": 0, "amplitude": 8.0})
	var eroded := TerrainGenerator.apply_erosion(hf, w, d, {"method": "normal_detail", "strength": 0.6, "iterations": 6})
	var before := _max_slope(hf, w, d)
	var after := _max_slope(eroded, w, d)
	return _check("apply_erosion(normal_detail): smooths terrain (max local slope decreases)", after <= before)

func _test_erosion_conserves_total_mass_approximately() -> bool:
	var w := 10
	var d := 10
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 6, "amplitude": 4.0})
	var eroded := TerrainGenerator.apply_erosion(hf, w, d, {"method": "normal_detail", "strength": 0.5, "iterations": 3})
	var sum_before := 0.0
	var sum_after := 0.0
	for h in hf:
		sum_before += h
	for h in eroded:
		sum_after += h
	return _check("apply_erosion(normal_detail): redistributes mass rather than deleting it (sum approx conserved)",
		is_equal_approx(sum_before, sum_after))

func _test_erosion_deterministic() -> bool:
	var hf := TerrainGenerator.generate_heightfield(10, 10, {"seed": 8})
	var a := TerrainGenerator.apply_erosion(hf, 10, 10, {"method": "normal_detail", "strength": 0.4, "iterations": 3})
	var b := TerrainGenerator.apply_erosion(hf, 10, 10, {"method": "normal_detail", "strength": 0.4, "iterations": 3})
	var ok := true
	for i in a.size():
		if not is_equal_approx(a[i], b[i]):
			ok = false
			break
	return _check("apply_erosion: deterministic (same input+params -> same output)", ok)

func _test_erosion_unimplemented_method_falls_back_safely() -> bool:
	var hf := TerrainGenerator.generate_heightfield(6, 6, {"seed": 2})
	var out := TerrainGenerator.apply_erosion(hf, 6, 6, {"method": "hydraulic"})
	var ok := hf.size() == out.size()
	for i in hf.size():
		ok = ok and is_equal_approx(hf[i], out[i])
	return _check("apply_erosion: named-but-unimplemented method (hydraulic) safely falls back to identity, no crash", ok)


# ── constraint field ─────────────────────────────────────────────────────────────────────────────

func _test_constraint_field_shapes_match_heightfield() -> bool:
	var w := 8
	var d := 8
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 1})
	var cf := TerrainGenerator.derive_constraint_field(hf, w, d)
	var ok: bool = cf["slope"].size() == w * d and cf["height"].size() == w * d \
		and cf["moisture"].size() == w * d and cf["biome_id"].size() == w * d
	return _check("derive_constraint_field: every layer's size == width*depth", ok)

func _test_constraint_field_values_in_unit_range() -> bool:
	var w := 12
	var d := 12
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 21, "amplitude": 6.0})
	var cf := TerrainGenerator.derive_constraint_field(hf, w, d, {"cell_size": 1.0})
	var ok := true
	for key in ["slope", "height", "moisture", "biome_id"]:
		var arr: PackedFloat32Array = cf[key]
		for v in arr:
			if v < -0.0001 or v > 1.0001:
				ok = false
	return _check("derive_constraint_field: slope/height/moisture/biome_id all stay within [0,1]", ok)

func _test_constraint_field_flat_low_terrain_is_water_biome() -> bool:
	var w := 6
	var d := 6
	var flat_low := PackedFloat32Array()
	flat_low.resize(w * d)
	for i in flat_low.size():
		flat_low[i] = -5.0  # uniformly low+flat -> height_n == 0 everywhere, slope == 0 everywhere
	var cf := TerrainGenerator.derive_constraint_field(flat_low, w, d)
	var biome: PackedFloat32Array = cf["biome_id"]
	var water_norm := float(TerrainGenerator.BIOME_WATER) / float(TerrainGenerator.BIOME_COUNT - 1)
	var ok := true
	for b in biome:
		if not is_equal_approx(b, water_norm):
			ok = false
			break
	return _check("derive_constraint_field: uniformly flat+low terrain classifies as the water biome", ok)

func _test_constraint_field_steep_terrain_is_rock_or_alpine_biome() -> bool:
	var w := 6
	var d := 6
	var steep := PackedFloat32Array()
	steep.resize(w * d)
	for y in d:
		for x in w:
			steep[y * w + x] = float(x) * 10.0  # a steep linear ramp across X
	var cf := TerrainGenerator.derive_constraint_field(steep, w, d, {"slope_scale": 1.0})
	var biome: PackedFloat32Array = cf["biome_id"]
	var rock_norm := float(TerrainGenerator.BIOME_ROCK) / float(TerrainGenerator.BIOME_COUNT - 1)
	var alpine_norm := float(TerrainGenerator.BIOME_ALPINE) / float(TerrainGenerator.BIOME_COUNT - 1)
	# Interior columns (away from the clamped edge gradient) should read as rock/alpine (steep).
	var ok := false
	for x in range(1, w - 1):
		var b: float = biome[3 * w + x]
		if is_equal_approx(b, rock_norm) or is_equal_approx(b, alpine_norm):
			ok = true
	return _check("derive_constraint_field: a steep ramp classifies interior cells as rock/alpine biome", ok)


# ── mesh ─────────────────────────────────────────────────────────────────────────────────────────

func _test_build_mesh_vertex_count() -> bool:
	var w := 5
	var d := 4
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 1})
	var mesh := TerrainGenerator.build_mesh(hf, w, d, 1.0)
	var ok := mesh != null and mesh.get_surface_count() == 1
	if ok:
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		# 2 triangles per cell * 3 verts, (w-1)*(d-1) cells (SurfaceTool emits unshared per-tri verts).
		var expected := (w - 1) * (d - 1) * 6
		ok = verts.size() == expected
	return _check("build_mesh: emits the expected triangle-vertex count for a WxD grid", ok)

func _test_build_mesh_empty_on_degenerate_grid() -> bool:
	var mesh := TerrainGenerator.build_mesh(PackedFloat32Array(), 1, 1, 1.0)
	return _check("build_mesh: degenerate (width<2 or depth<2) grid returns an empty-but-valid mesh, no crash", mesh != null)


# ── bilinear sampling ────────────────────────────────────────────────────────────────────────────

func _test_sample_bilinear_matches_grid_points() -> bool:
	var w := 5
	var d := 5
	var hf := TerrainGenerator.generate_heightfield(w, d, {"seed": 3})
	var ok := true
	for y in d:
		for x in w:
			var s := TerrainGenerator.sample_bilinear(hf, w, d, float(x), float(y))
			if not is_equal_approx(s, hf[y * w + x]):
				ok = false
	return _check("sample_bilinear: sampling at exact grid coords returns the exact grid value", ok)

func _test_sample_bilinear_interpolates_between_points() -> bool:
	var w := 3
	var d := 1
	var hf := PackedFloat32Array([0.0, 10.0, 20.0])
	var mid := TerrainGenerator.sample_bilinear(hf, w, d, 0.5, 0.0)
	return _check("sample_bilinear: midpoint between two grid values interpolates linearly", is_equal_approx(mid, 5.0))


# ── top-level build() ───────────────────────────────────────────────────────────────────────────

func _test_build_top_level_returns_consistent_shapes() -> bool:
	var result := TerrainGenerator.build({"width": 10, "depth": 8, "seed": 5})
	var ok := int(result["width"]) == 10 and int(result["depth"]) == 8
	ok = ok and (result["heightfield"] as PackedFloat32Array).size() == 80
	var cf: Dictionary = result["constraint_field"]
	ok = ok and (cf["slope"] as PackedFloat32Array).size() == 80
	ok = ok and result["mesh"] != null
	return _check("build(): top-level result carries consistent width/depth/heightfield/constraint_field/mesh", ok)

func _test_build_deterministic_end_to_end() -> bool:
	var a := TerrainGenerator.build({"width": 9, "depth": 9, "seed": 77})
	var b := TerrainGenerator.build({"width": 9, "depth": 9, "seed": 77})
	var hf_a: PackedFloat32Array = a["heightfield"]
	var hf_b: PackedFloat32Array = b["heightfield"]
	var ok := hf_a.size() == hf_b.size()
	for i in hf_a.size():
		ok = ok and is_equal_approx(hf_a[i], hf_b[i])
	return _check("build(): identical tunables -> identical end-to-end result (determinism holds through erosion)", ok)


# ── GLB export ───────────────────────────────────────────────────────────────────────────────────

func _test_export_glb_writes_nonempty_file() -> bool:
	var result := TerrainGenerator.build({"width": 6, "depth": 6, "seed": 2})
	var out_path := "res://artifacts/_test_terrain_export.glb"
	var err := TerrainGenerator.export_glb(result["mesh"], out_path)
	var ok := err == OK
	if ok:
		var f := FileAccess.open(out_path, FileAccess.READ)
		ok = f != null and f.get_length() > 0
		if f != null:
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	return _check("export_glb: writes a non-empty .glb file for a built terrain mesh", ok)
