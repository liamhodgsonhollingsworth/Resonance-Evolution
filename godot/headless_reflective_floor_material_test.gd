extends SceneTree
## Headless test suite for renderers/reflective_floor_material.gd (ReflectiveFloorMaterial, Wave 3
## item 3.2 node 4, DQ-2e1202ca):
##
##   godot --headless --path godot -s res://headless_reflective_floor_material_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_default_material_color_and_roughness() and ok
	ok = _test_default_material_not_metallic() and ok
	ok = _test_gloss_tunable_controls_roughness_inversely() and ok
	ok = _test_roughness_tunable_accepted_as_alternate_axis() and ok
	ok = _test_gloss_wins_when_both_given() and ok
	ok = _test_custom_base_color_respected() and ok
	ok = _test_default_mode_is_ssr() and ok
	ok = _test_ssr_patch_shape() and ok
	ok = _test_cheap_fresnel_disables_ssr_and_enables_rim() and ok
	ok = _test_planar_falls_back_to_ssr_patch() and ok
	ok = _test_unknown_mode_falls_back_to_default() and ok
	ok = _test_apply_environment_writes_ssr_fields() and ok
	ok = _test_apply_environment_cheap_fresnel_disables_ssr_only() and ok
	ok = _test_apply_environment_null_env_does_not_crash() and ok
	ok = _test_build_top_level_shape() and ok
	ok = _test_ssr_custom_steps_respected() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── build_material() ────────────────────────────────────────────────────────────────────────────

func _test_default_material_color_and_roughness() -> bool:
	var mat := ReflectiveFloorMaterial.build_material()
	var ok := mat.albedo_color.is_equal_approx(ReflectiveFloorMaterial.DEFAULT_BASE_COLOR)
	ok = ok and is_equal_approx(mat.roughness, 1.0 - ReflectiveFloorMaterial.DEFAULT_GLOSS)
	return _check("build_material: default base_color + roughness = 1-DEFAULT_GLOSS", ok)

func _test_default_material_not_metallic() -> bool:
	var mat := ReflectiveFloorMaterial.build_material()
	return _check("build_material: metallic stays 0 (glossy dielectric, not chrome)", is_equal_approx(mat.metallic, 0.0))

func _test_gloss_tunable_controls_roughness_inversely() -> bool:
	var glossy := ReflectiveFloorMaterial.build_material({"gloss": 1.0})
	var matte := ReflectiveFloorMaterial.build_material({"gloss": 0.0})
	var ok := is_equal_approx(glossy.roughness, 0.0) and is_equal_approx(matte.roughness, 1.0)
	return _check("build_material: gloss=1.0 -> roughness=0.0 (mirror-sharp); gloss=0.0 -> roughness=1.0", ok)

func _test_roughness_tunable_accepted_as_alternate_axis() -> bool:
	var mat := ReflectiveFloorMaterial.build_material({"roughness": 0.3})
	return _check("build_material: 'roughness' tunable accepted directly when 'gloss' is absent", is_equal_approx(mat.roughness, 0.3))

func _test_gloss_wins_when_both_given() -> bool:
	var mat := ReflectiveFloorMaterial.build_material({"gloss": 0.9, "roughness": 0.7})
	return _check("build_material: 'gloss' wins over 'roughness' when both are given", is_equal_approx(mat.roughness, 0.1))

func _test_custom_base_color_respected() -> bool:
	var c := Color(0.8, 0.1, 0.1)
	var mat := ReflectiveFloorMaterial.build_material({"base_color": c})
	return _check("build_material: custom base_color respected", mat.albedo_color.is_equal_approx(c))


# ── build_environment_patch() / reflection_mode ─────────────────────────────────────────────────

func _test_default_mode_is_ssr() -> bool:
	var patch := ReflectiveFloorMaterial.build_environment_patch({})
	return _check("build_environment_patch: default reflection_mode is ssr (ssr_enabled=true)", bool(patch.get("ssr_enabled", false)) == true)

func _test_ssr_patch_shape() -> bool:
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "ssr"})
	var ok := patch.has("ssr_max_steps") and patch.has("ssr_fade_in") and patch.has("ssr_fade_out") and patch.has("ssr_depth_tolerance")
	return _check("build_environment_patch: ssr mode carries every SSR field", ok)

func _test_cheap_fresnel_disables_ssr_and_enables_rim() -> bool:
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "cheap_fresnel"})
	var mat := ReflectiveFloorMaterial.build_material({"reflection_mode": "cheap_fresnel"})
	var ok := bool(patch.get("ssr_enabled", true)) == false and mat.rim_enabled == true
	return _check("cheap_fresnel: ssr_enabled=false in the env patch AND material.rim_enabled=true", ok)

func _test_planar_falls_back_to_ssr_patch() -> bool:
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "planar"})
	return _check("planar (not yet implemented, plan §2.3 escalation rung): falls back to the ssr patch, not a silent no-op",
		bool(patch.get("ssr_enabled", false)) == true)

func _test_unknown_mode_falls_back_to_default() -> bool:
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "not_a_real_mode"})
	return _check("build_environment_patch: unknown reflection_mode falls back to DEFAULT_REFLECTION_MODE (ssr)",
		bool(patch.get("ssr_enabled", false)) == true)


# ── apply_environment() ─────────────────────────────────────────────────────────────────────────

func _test_apply_environment_writes_ssr_fields() -> bool:
	var env := Environment.new()
	env.ssr_enabled = false
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "ssr", "ssr_max_steps": 32})
	ReflectiveFloorMaterial.apply_environment(env, patch)
	return _check("apply_environment: writes ssr_enabled + ssr_max_steps onto a real Environment", env.ssr_enabled == true and env.ssr_max_steps == 32)

func _test_apply_environment_cheap_fresnel_disables_ssr_only() -> bool:
	var env := Environment.new()
	env.ssr_enabled = true
	env.ssr_max_steps = 99
	var patch := ReflectiveFloorMaterial.build_environment_patch({"reflection_mode": "cheap_fresnel"})
	ReflectiveFloorMaterial.apply_environment(env, patch)
	# cheap_fresnel's patch only sets ssr_enabled=false; ssr_max_steps (absent from the patch) must
	# be left exactly as the caller had it -- proves apply_environment doesn't stomp unrelated fields.
	return _check("apply_environment: cheap_fresnel patch disables ssr_enabled but leaves other SSR fields untouched",
		env.ssr_enabled == false and env.ssr_max_steps == 99)

func _test_apply_environment_null_env_does_not_crash() -> bool:
	ReflectiveFloorMaterial.apply_environment(null, {"ssr_enabled": true})
	return _check("apply_environment: null Environment is a safe no-op", true)


# ── build() top-level ───────────────────────────────────────────────────────────────────────────

func _test_build_top_level_shape() -> bool:
	var result := ReflectiveFloorMaterial.build({"gloss": 0.7})
	var ok := result.has("material") and result.has("environment_patch")
	ok = ok and result["material"] is StandardMaterial3D and result["environment_patch"] is Dictionary
	return _check("build(): top-level shape is {material, environment_patch} (the plan's single floor_material_descriptor)", ok)

func _test_ssr_custom_steps_respected() -> bool:
	var result := ReflectiveFloorMaterial.build({"ssr_max_steps": 16, "ssr_fade_in": 0.5})
	var patch: Dictionary = result["environment_patch"]
	return _check("build(): custom SSR sub-tunables flow through to the environment_patch", int(patch["ssr_max_steps"]) == 16 and is_equal_approx(float(patch["ssr_fade_in"]), 0.5))
