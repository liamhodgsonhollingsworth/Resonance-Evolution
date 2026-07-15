extends SceneTree
## Headless test suite for renderers/roof_glow_cutoff.gd (RoofGlowCutoff, Wave 4 item 4.1 (B),
## DQ-60f088f7):
##
##   godot --headless --path godot -s res://headless_roof_glow_cutoff_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_blend_factor_below_cutoff_is_zero() and ok
	ok = _test_blend_factor_at_cutoff_plus_softness_is_one() and ok
	ok = _test_blend_factor_midpoint_is_half() and ok
	ok = _test_blend_factor_clamps_beyond_range() and ok
	ok = _test_blend_factor_zero_softness_does_not_crash() and ok
	ok = _test_build_material_default_params() and ok
	ok = _test_build_material_custom_params() and ok
	ok = _test_build_material_no_base_texture_by_default() and ok
	ok = _test_build_material_base_texture_flag_set_when_texture_given() and ok
	ok = _test_from_wall_material_lifts_color_and_roughness() and ok
	ok = _test_from_wall_material_null_base_uses_defaults() and ok
	ok = _test_shader_code_contains_expected_uniforms_and_formula() and ok
	ok = _test_overlay_shader_code_is_additive_unshaded() and ok
	ok = _test_build_overlay_material_params() and ok
	ok = _test_apply_as_overlay_sets_next_pass() and ok
	ok = _test_apply_as_overlay_null_base_is_safe_noop() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── blend_factor() (the GDScript twin of both shaders' fragment() formula) ─────────────────────────

func _test_blend_factor_below_cutoff_is_zero() -> bool:
	return _check("blend_factor: world_y well below cutoff -> 0.0",
		is_equal_approx(RoofGlowCutoff.blend_factor(0.0, 2.4, 0.6), 0.0))

func _test_blend_factor_at_cutoff_plus_softness_is_one() -> bool:
	return _check("blend_factor: world_y == cutoff+softness -> 1.0",
		is_equal_approx(RoofGlowCutoff.blend_factor(3.0, 2.4, 0.6), 1.0))

func _test_blend_factor_midpoint_is_half() -> bool:
	return _check("blend_factor: world_y == cutoff+softness/2 -> 0.5",
		is_equal_approx(RoofGlowCutoff.blend_factor(2.7, 2.4, 0.6), 0.5))

func _test_blend_factor_clamps_beyond_range() -> bool:
	var below := RoofGlowCutoff.blend_factor(-100.0, 2.4, 0.6)
	var above := RoofGlowCutoff.blend_factor(100.0, 2.4, 0.6)
	return _check("blend_factor: clamps to [0,1] far outside the transition band",
		is_equal_approx(below, 0.0) and is_equal_approx(above, 1.0))

func _test_blend_factor_zero_softness_does_not_crash() -> bool:
	var t := RoofGlowCutoff.blend_factor(5.0, 2.4, 0.0)
	return _check("blend_factor: blend_softness=0.0 is a safe hard-edge cutoff (no div-by-zero)", t >= 0.0 and t <= 1.0)


# ── build_material() (full-replacement mode) ────────────────────────────────────────────────────

func _test_build_material_default_params() -> bool:
	var mat := RoofGlowCutoff.build_material()
	var ok := is_equal_approx(float(mat.get_shader_parameter("cutoff_elevation")), RoofGlowCutoff.DEFAULT_CUTOFF_ELEVATION)
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("glow_energy")), RoofGlowCutoff.DEFAULT_GLOW_ENERGY)
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("blend_softness")), RoofGlowCutoff.DEFAULT_BLEND_SOFTNESS)
	ok = ok and (mat.get_shader_parameter("glow_color") as Color).is_equal_approx(RoofGlowCutoff.DEFAULT_GLOW_COLOR)
	ok = ok and (mat.get_shader_parameter("base_color") as Color).is_equal_approx(RoofGlowCutoff.DEFAULT_BASE_COLOR)
	return _check("build_material: default shader params match the module's DEFAULT_* constants", ok)

func _test_build_material_custom_params() -> bool:
	var mat := RoofGlowCutoff.build_material({
		"cutoff_elevation": 5.0, "glow_energy": 9.0, "blend_softness": 1.2,
		"glow_color": Color(1.0, 0.5, 0.5), "base_color": Color(0.2, 0.2, 0.2), "base_roughness": 0.4,
	})
	var ok := is_equal_approx(float(mat.get_shader_parameter("cutoff_elevation")), 5.0)
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("glow_energy")), 9.0)
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("blend_softness")), 1.2)
	ok = ok and (mat.get_shader_parameter("glow_color") as Color).is_equal_approx(Color(1.0, 0.5, 0.5))
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("base_roughness")), 0.4)
	return _check("build_material: custom tunables flow through to shader params", ok)

func _test_build_material_no_base_texture_by_default() -> bool:
	var mat := RoofGlowCutoff.build_material()
	return _check("build_material: use_base_texture=false when no base_texture given",
		bool(mat.get_shader_parameter("use_base_texture")) == false)

func _test_build_material_base_texture_flag_set_when_texture_given() -> bool:
	var tex := ImageTexture.create_from_image(Image.create(4, 4, false, Image.FORMAT_RGB8))
	var mat := RoofGlowCutoff.build_material({"base_texture": tex})
	return _check("build_material: use_base_texture=true when a Texture2D is given",
		bool(mat.get_shader_parameter("use_base_texture")) == true)


# ── from_wall_material() ────────────────────────────────────────────────────────────────────────

func _test_from_wall_material_lifts_color_and_roughness() -> bool:
	var base := StandardMaterial3D.new()
	base.albedo_color = Color(0.3, 0.6, 0.2)
	base.roughness = 0.55
	var mat := RoofGlowCutoff.from_wall_material(base)
	var ok := (mat.get_shader_parameter("base_color") as Color).is_equal_approx(Color(0.3, 0.6, 0.2))
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("base_roughness")), 0.55)
	return _check("from_wall_material: lifts albedo_color + roughness from the given StandardMaterial3D", ok)

func _test_from_wall_material_null_base_uses_defaults() -> bool:
	var mat := RoofGlowCutoff.from_wall_material(null)
	return _check("from_wall_material: null base falls back to module defaults, no crash",
		(mat.get_shader_parameter("base_color") as Color).is_equal_approx(RoofGlowCutoff.DEFAULT_BASE_COLOR))


# ── shader source shape ─────────────────────────────────────────────────────────────────────────

func _test_shader_code_contains_expected_uniforms_and_formula() -> bool:
	var code := RoofGlowCutoff.build_shader_code()
	var ok := code.begins_with("shader_type spatial;")
	ok = ok and code.contains("uniform float cutoff_elevation")
	ok = ok and code.contains("uniform float blend_softness")
	ok = ok and code.contains("uniform vec4 glow_color")
	ok = ok and code.contains("EMISSION = glow_color.rgb * glow_energy * t;")
	return _check("build_shader_code: spatial shader declares cutoff/softness/glow uniforms + the EMISSION formula", ok)

func _test_overlay_shader_code_is_additive_unshaded() -> bool:
	var code := RoofGlowCutoff.build_overlay_shader_code()
	var ok := code.contains("render_mode blend_add, unshaded")
	ok = ok and code.contains("ALBEDO = glow_color.rgb * glow_energy * t;")
	ok = ok and not code.contains("base_color")  # overlay never touches a base appearance
	return _check("build_overlay_shader_code: unshaded + blend_add, no base-color mixing (pure additive)", ok)


# ── overlay mode ─────────────────────────────────────────────────────────────────────────────────

func _test_build_overlay_material_params() -> bool:
	var mat := RoofGlowCutoff.build_overlay_material({"cutoff_elevation": 3.3, "glow_energy": 4.4})
	var ok := is_equal_approx(float(mat.get_shader_parameter("cutoff_elevation")), 3.3)
	ok = ok and is_equal_approx(float(mat.get_shader_parameter("glow_energy")), 4.4)
	return _check("build_overlay_material: tunables flow through to the overlay shader params", ok)

func _test_apply_as_overlay_sets_next_pass() -> bool:
	var base := StandardMaterial3D.new()
	base.albedo_color = Color(0.4, 0.4, 0.4)
	var returned := RoofGlowCutoff.apply_as_overlay(base, {"cutoff_elevation": 2.0})
	var ok := returned == base
	ok = ok and base.next_pass is ShaderMaterial
	ok = ok and base.albedo_color.is_equal_approx(Color(0.4, 0.4, 0.4))  # base material itself untouched
	return _check("apply_as_overlay: chains the glow overlay via next_pass, base material otherwise unchanged", ok)

func _test_apply_as_overlay_null_base_is_safe_noop() -> bool:
	var result := RoofGlowCutoff.apply_as_overlay(null, {})
	return _check("apply_as_overlay: null base_material is a safe no-op (returns null, no crash)", result == null)
