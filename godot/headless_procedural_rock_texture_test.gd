extends SceneTree
## Headless test suite for renderers/procedural_rock_texture.gd (ProceduralRockTexture, Wave 3
## item 3.2 node 3, DQ-2e1202ca):
##
##   godot --headless --path godot -s res://headless_procedural_rock_texture_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_default_ops_use_known_op_types() and ok
	ok = _test_ops_carry_the_given_seed() and ok
	ok = _test_ops_carry_the_resolved_palette() and ok
	ok = _test_unknown_palette_falls_back_to_default() and ok
	ok = _test_noise_scale_influences_voronoi_cell_count() and ok
	ok = _test_synthesize_returns_correct_size_at_full_detail() and ok
	ok = _test_synthesize_shrinks_toward_min_tile_at_zero_detail() and ok
	ok = _test_synthesize_is_deterministic_by_seed() and ok
	ok = _test_synthesize_different_seed_differs() and ok
	ok = _test_synthesize_different_palette_differs() and ok
	ok = _test_build_material_has_albedo_texture() and ok
	ok = _test_build_material_default_roughness() and ok
	ok = _test_build_material_custom_roughness_respected() and ok
	ok = _test_build_material_is_not_metallic() and ok
	ok = _test_build_material_uv_scale_reflects_world_units_per_tile() and ok
	ok = _test_build_material_cross_section_repeat_is_fixed() and ok
	ok = _test_build_material_accepts_wall_uv_without_erroring() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── build_texture_ops() ─────────────────────────────────────────────────────────────────────────

func _test_default_ops_use_known_op_types() -> bool:
	var desc := ProceduralRockTexture.build_texture_ops({})
	var ops: Array = desc["texture_ops"]
	var ok := ops.size() >= 3
	for op in ops:
		ok = ok and TextureSynthCpu.OP_TYPES.has(String(op["type"]))
	return _check("build_texture_ops: every emitted op type is a real TextureSynthCpu.OP_TYPES entry", ok)

func _test_ops_carry_the_given_seed() -> bool:
	var desc := ProceduralRockTexture.build_texture_ops({"noise_seed": 999})
	var ops: Array = desc["texture_ops"]
	var first_seed: int = int((ops[0]["params"] as Dictionary).get("seed", -1))
	return _check("build_texture_ops: noise_seed propagates into the op params", first_seed == 999)

func _test_ops_carry_the_resolved_palette() -> bool:
	var desc := ProceduralRockTexture.build_texture_ops({"palette_handle": "ember"})
	var ops: Array = desc["texture_ops"]
	var ok := true
	for op in ops:
		ok = ok and String((op["params"] as Dictionary).get("palette", "")) == "ember"
	return _check("build_texture_ops: palette_handle propagates onto every op", ok)

func _test_unknown_palette_falls_back_to_default() -> bool:
	var desc := ProceduralRockTexture.build_texture_ops({"palette_handle": "not_a_real_palette"})
	var ops: Array = desc["texture_ops"]
	var ok := String((ops[0]["params"] as Dictionary).get("palette", "")) == ProceduralRockTexture.DEFAULT_PALETTE
	return _check("build_texture_ops: unknown palette_handle falls back to DEFAULT_PALETTE (not crash/passthrough)", ok)

func _test_noise_scale_influences_voronoi_cell_count() -> bool:
	var small := ProceduralRockTexture.build_texture_ops({"noise_scale": 2.0})
	var large := ProceduralRockTexture.build_texture_ops({"noise_scale": 14.0})
	var small_cells := int((small["texture_ops"][1]["params"] as Dictionary).get("cells", 0))
	var large_cells := int((large["texture_ops"][1]["params"] as Dictionary).get("cells", 0))
	return _check("build_texture_ops: larger noise_scale increases voronoi cell count", large_cells > small_cells)


# ── synthesize() ─────────────────────────────────────────────────────────────────────────────────

func _test_synthesize_returns_correct_size_at_full_detail() -> bool:
	var img := ProceduralRockTexture.synthesize({}, 1.0)
	var ok := img.get_width() == ProceduralRockTexture.DEFAULT_TILE_PX and img.get_height() == ProceduralRockTexture.DEFAULT_TILE_PX
	return _check("synthesize: detail=1.0 -> DEFAULT_TILE_PX square image", ok)

func _test_synthesize_shrinks_toward_min_tile_at_zero_detail() -> bool:
	var img := ProceduralRockTexture.synthesize({}, 0.0)
	var ok := img.get_width() == ProceduralRockTexture.MIN_TILE_PX
	return _check("synthesize: detail=0.0 -> MIN_TILE_PX square image (LOD budget wiring)", ok)

func _test_synthesize_is_deterministic_by_seed() -> bool:
	var tunables := {"noise_seed": 55, "noise_scale": 4.0, "palette_handle": "slate"}
	var a := ProceduralRockTexture.synthesize(tunables, 1.0)
	var b := ProceduralRockTexture.synthesize(tunables, 1.0)
	return _check("synthesize: same tunables -> byte-identical image", a.get_data() == b.get_data())

func _test_synthesize_different_seed_differs() -> bool:
	var a := ProceduralRockTexture.synthesize({"noise_seed": 1}, 1.0)
	var b := ProceduralRockTexture.synthesize({"noise_seed": 2}, 1.0)
	return _check("synthesize: different noise_seed -> different image bytes", a.get_data() != b.get_data())

func _test_synthesize_different_palette_differs() -> bool:
	var a := ProceduralRockTexture.synthesize({"palette_handle": "slate"}, 1.0)
	var b := ProceduralRockTexture.synthesize({"palette_handle": "ember"}, 1.0)
	return _check("synthesize: different palette_handle -> different image bytes", a.get_data() != b.get_data())


# ── build_material() ────────────────────────────────────────────────────────────────────────────

func _test_build_material_has_albedo_texture() -> bool:
	var mat := ProceduralRockTexture.build_material()
	return _check("build_material: albedo_texture is set", mat.albedo_texture != null)

func _test_build_material_default_roughness() -> bool:
	var mat := ProceduralRockTexture.build_material()
	return _check("build_material: default roughness matches DEFAULT_ROUGHNESS",
		is_equal_approx(mat.roughness, ProceduralRockTexture.DEFAULT_ROUGHNESS))

func _test_build_material_custom_roughness_respected() -> bool:
	var mat := ProceduralRockTexture.build_material({"roughness": 0.4})
	return _check("build_material: custom roughness tunable respected", is_equal_approx(mat.roughness, 0.4))

func _test_build_material_is_not_metallic() -> bool:
	var mat := ProceduralRockTexture.build_material()
	return _check("build_material: metallic stays 0 (rock is a dielectric, not chrome)", is_equal_approx(mat.metallic, 0.0))

func _test_build_material_uv_scale_reflects_world_units_per_tile() -> bool:
	var mat := ProceduralRockTexture.build_material({"world_units_per_tile": 5.0})
	return _check("build_material: uv1_scale.x = 1/world_units_per_tile", is_equal_approx(mat.uv1_scale.x, 0.2))

func _test_build_material_cross_section_repeat_is_fixed() -> bool:
	var mat := ProceduralRockTexture.build_material()
	return _check("build_material: uv1_scale.y = CROSS_SECTION_TILE_REPEATS",
		is_equal_approx(mat.uv1_scale.y, ProceduralRockTexture.CROSS_SECTION_TILE_REPEATS))

func _test_build_material_accepts_wall_uv_without_erroring() -> bool:
	# Real wall_surface_uv() input (node 3's plan-named In port), composed straight from
	# RingScaffoldGenerator -- proves the two nodes' contracts actually fit together, not just a
	# hand-rolled fake dict.
	var ring_data: Dictionary = RingScaffoldGenerator.build_topology(1, 5.0, 4.0, 0.0)[0]
	var wall_uv := RingScaffoldGenerator.wall_surface_uv(ring_data)
	var mat := ProceduralRockTexture.build_material({}, wall_uv)
	return _check("build_material: composes with a real RingScaffoldGenerator.wall_surface_uv() descriptor",
		mat != null and mat.albedo_texture != null)
