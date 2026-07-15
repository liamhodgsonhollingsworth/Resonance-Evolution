extends SceneTree
## Headless test suite for renderers/atmospheric_fog_volume.gd (AtmosphericFogVolume, Wave 4 item
## 4.1 (C), DQ-60f088f7):
##
##   godot --headless --path godot -s res://headless_atmospheric_fog_volume_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_default_patch_shape() and ok
	ok = _test_default_density_and_color() and ok
	ok = _test_custom_density_and_color_respected() and ok
	ok = _test_height_falloff_tunables_respected() and ok
	ok = _test_sun_scatter_respected() and ok
	ok = _test_volumetric_disabled_by_default_and_no_extra_keys() and ok
	ok = _test_volumetric_enabled_adds_density_and_albedo_keys() and ok
	ok = _test_apply_environment_writes_distance_fog_fields() and ok
	ok = _test_apply_environment_writes_volumetric_fields_when_present() and ok
	ok = _test_apply_environment_leaves_absent_fields_untouched() and ok
	ok = _test_apply_environment_null_env_does_not_crash() and ok
	ok = _test_build_top_level_shape() and ok
	ok = _test_density_clamped_to_unit_range() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── build_environment_patch() ───────────────────────────────────────────────────────────────────

func _test_default_patch_shape() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch()
	var ok := patch.has("fog_enabled") and patch.has("fog_density") and patch.has("fog_light_color")
	ok = ok and patch.has("fog_height") and patch.has("fog_height_density") and patch.has("fog_sun_scatter")
	ok = ok and patch.has("volumetric_fog_enabled")
	return _check("build_environment_patch: default patch carries every distance-fog field + the volumetric flag", ok)

func _test_default_density_and_color() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch()
	var ok := bool(patch["fog_enabled"]) == true
	ok = ok and is_equal_approx(float(patch["fog_density"]), AtmosphericFogVolume.DEFAULT_DENSITY)
	ok = ok and (patch["fog_light_color"] as Color).is_equal_approx(AtmosphericFogVolume.DEFAULT_COLOR)
	return _check("build_environment_patch: defaults match DEFAULT_DENSITY / DEFAULT_COLOR, fog_enabled=true", ok)

func _test_custom_density_and_color_respected() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch({"density": 0.2, "color": Color(0.1, 0.2, 0.9)})
	var ok := is_equal_approx(float(patch["fog_density"]), 0.2)
	ok = ok and (patch["fog_light_color"] as Color).is_equal_approx(Color(0.1, 0.2, 0.9))
	return _check("build_environment_patch: custom density/color tunables respected", ok)

func _test_height_falloff_tunables_respected() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch({"height": 1.5, "height_density": 0.3})
	var ok := is_equal_approx(float(patch["fog_height"]), 1.5)
	ok = ok and is_equal_approx(float(patch["fog_height_density"]), 0.3)
	return _check("build_environment_patch: height/height_density tunables respected", ok)

func _test_sun_scatter_respected() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch({"sun_scatter": 0.4})
	return _check("build_environment_patch: sun_scatter tunable respected", is_equal_approx(float(patch["fog_sun_scatter"]), 0.4))

func _test_volumetric_disabled_by_default_and_no_extra_keys() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch()
	var ok := bool(patch["volumetric_fog_enabled"]) == false
	ok = ok and not patch.has("volumetric_fog_density") and not patch.has("volumetric_fog_albedo")
	return _check("build_environment_patch: volumetric off by default, no volumetric_fog_density/albedo keys emitted", ok)

func _test_volumetric_enabled_adds_density_and_albedo_keys() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch({"volumetric_enabled": true, "volumetric_density": 0.08, "color": Color(0.3, 0.3, 0.3)})
	var ok := bool(patch["volumetric_fog_enabled"]) == true
	ok = ok and is_equal_approx(float(patch["volumetric_fog_density"]), 0.08)
	ok = ok and (patch["volumetric_fog_albedo"] as Color).is_equal_approx(Color(0.3, 0.3, 0.3))
	return _check("build_environment_patch: volumetric_enabled=true adds volumetric_fog_density + volumetric_fog_albedo", ok)


# ── apply_environment() ─────────────────────────────────────────────────────────────────────────

func _test_apply_environment_writes_distance_fog_fields() -> bool:
	var env := Environment.new()
	env.fog_enabled = false
	var patch := AtmosphericFogVolume.build_environment_patch({"density": 0.11, "color": Color(0.2, 0.3, 0.4), "height": 1.0, "height_density": 0.05, "sun_scatter": 0.25})
	AtmosphericFogVolume.apply_environment(env, patch)
	var ok := env.fog_enabled == true
	ok = ok and is_equal_approx(env.fog_density, 0.11)
	ok = ok and env.fog_light_color.is_equal_approx(Color(0.2, 0.3, 0.4))
	ok = ok and is_equal_approx(env.fog_height, 1.0)
	ok = ok and is_equal_approx(env.fog_height_density, 0.05)
	ok = ok and is_equal_approx(env.fog_sun_scatter, 0.25)
	return _check("apply_environment: writes every distance-fog field onto a real Environment", ok)

func _test_apply_environment_writes_volumetric_fields_when_present() -> bool:
	var env := Environment.new()
	env.volumetric_fog_enabled = false
	var patch := AtmosphericFogVolume.build_environment_patch({"volumetric_enabled": true, "volumetric_density": 0.06})
	AtmosphericFogVolume.apply_environment(env, patch)
	var ok := env.volumetric_fog_enabled == true
	ok = ok and is_equal_approx(env.volumetric_fog_density, 0.06)
	return _check("apply_environment: writes volumetric_fog_enabled/density when the patch carries them", ok)

func _test_apply_environment_leaves_absent_fields_untouched() -> bool:
	var env := Environment.new()
	env.volumetric_fog_density = 0.77
	var patch := AtmosphericFogVolume.build_environment_patch({"volumetric_enabled": false})  # no volumetric density key emitted
	AtmosphericFogVolume.apply_environment(env, patch)
	return _check("apply_environment: fields absent from the patch (volumetric density, when disabled) are left untouched",
		is_equal_approx(env.volumetric_fog_density, 0.77))

func _test_apply_environment_null_env_does_not_crash() -> bool:
	AtmosphericFogVolume.apply_environment(null, {"fog_enabled": true})
	return _check("apply_environment: null Environment is a safe no-op", true)


# ── build() top-level ───────────────────────────────────────────────────────────────────────────

func _test_build_top_level_shape() -> bool:
	var result := AtmosphericFogVolume.build({"density": 0.07})
	var ok := result.has("environment_patch") and result["environment_patch"] is Dictionary
	ok = ok and is_equal_approx(float(result["environment_patch"]["fog_density"]), 0.07)
	return _check("build(): top-level shape is {environment_patch} carrying the fog_descriptor", ok)

func _test_density_clamped_to_unit_range() -> bool:
	var patch := AtmosphericFogVolume.build_environment_patch({"density": 5.0})
	return _check("build_environment_patch: density is clamped to [0,1] even if a caller passes > 1",
		is_equal_approx(float(patch["fog_density"]), 1.0))
