extends SceneTree
## Headless test suite for renderers/sky_socket.gd (Wave-A1 increment 1, Project A node 9):
##
##   godot --headless --path godot -s res://headless_sky_socket_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_default_mode_is_blank_white() and ok
	ok = _test_blank_white_background_is_flat_white() and ok
	ok = _test_blank_white_sun_is_near_overhead_by_default() and ok
	ok = _test_sun_altitude_param_respected_and_clamped() and ok
	ok = _test_sun_azimuth_wraps() and ok
	ok = _test_light_energy_param_respected() and ok
	ok = _test_procedural_mode_delegates_to_painterly_sky() and ok
	ok = _test_unimplemented_mode_falls_back_to_blank_white() and ok
	ok = _test_unknown_mode_falls_back_to_blank_white() and ok
	ok = _test_build_return_shape_matches_painterly_sky() and ok
	ok = _test_sky_gd_untouched_still_builds_normally() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _test_default_mode_is_blank_white() -> bool:
	var result := SkySocket.build({})
	var env: Environment = result["environment"]
	return _check("build({}): omitted mode defaults to blank_white (BG_COLOR white)",
		env.background_mode == Environment.BG_COLOR and env.background_color.is_equal_approx(Color(1, 1, 1)))


func _test_blank_white_background_is_flat_white() -> bool:
	var result := SkySocket.build({"mode": "blank_white"})
	var env: Environment = result["environment"]
	var ok := env.background_mode == Environment.BG_COLOR
	ok = ok and env.background_color.is_equal_approx(Color(1.0, 1.0, 1.0))
	ok = ok and result["sun"] is DirectionalLight3D
	return _check("build(mode=blank_white): flat white BG_COLOR background + a DirectionalLight3D sun", ok)


func _test_blank_white_sun_is_near_overhead_by_default() -> bool:
	var result := SkySocket.build({"mode": "blank_white"})
	var sun: DirectionalLight3D = result["sun"]
	var altitude := SkySocket.altitude_of(sun)
	# Default 82 degrees, well within the plan's "near-overhead" 60-90 range.
	return _check("build(mode=blank_white): default sun altitude is near-overhead (>=75 deg)", altitude >= 75.0 and altitude <= 90.0)


func _test_sun_altitude_param_respected_and_clamped() -> bool:
	var result_low := SkySocket.build({"mode": "blank_white", "sun_altitude": 90.0})
	var alt_low := SkySocket.altitude_of(result_low["sun"])
	var ok := absf(alt_low - 90.0) < 0.5
	# Below the [60, 90] clamp range -- must clamp to 60, not crash / go negative.
	var result_clamped := SkySocket.build({"mode": "blank_white", "sun_altitude": 5.0})
	var alt_clamped := SkySocket.altitude_of(result_clamped["sun"])
	ok = ok and absf(alt_clamped - 60.0) < 0.5
	return _check("build(): sun_altitude is honored at 90 and clamped to the [60,90] range at 5", ok)


func _test_sun_azimuth_wraps() -> bool:
	var a := SkySocket.build({"mode": "blank_white", "sun_azimuth": 400.0})
	var b := SkySocket.build({"mode": "blank_white", "sun_azimuth": 40.0})
	var sun_a: DirectionalLight3D = a["sun"]
	var sun_b: DirectionalLight3D = b["sun"]
	return _check("build(): sun_azimuth=400 wraps to the same rotation as azimuth=40", absf(sun_a.rotation.y - sun_b.rotation.y) < 1e-4)


func _test_light_energy_param_respected() -> bool:
	var result := SkySocket.build({"mode": "blank_white", "light_energy": 2.5})
	var sun: DirectionalLight3D = result["sun"]
	return _check("build(): light_energy param sets the sun's light_energy", absf(sun.light_energy - 2.5) < 1e-4)


func _test_procedural_mode_delegates_to_painterly_sky() -> bool:
	var result := SkySocket.build({"mode": "procedural"})
	var env: Environment = result["environment"]
	# PainterlySky.build() always mounts a BG_SKY background (a real ProceduralSkyMaterial) --
	# distinctly NOT the blank-white BG_COLOR mode, proving delegation actually occurred.
	return _check("build(mode=procedural): delegates to PainterlySky.build() (BG_SKY, not BG_COLOR)", env.background_mode == Environment.BG_SKY)


func _test_unimplemented_mode_falls_back_to_blank_white() -> bool:
	var result := SkySocket.build({"mode": "clouds_painterly"})
	var env: Environment = result["environment"]
	return _check("build(mode=clouds_painterly): P3-phase mode gracefully falls back to blank_white, no crash", env.background_mode == Environment.BG_COLOR)


func _test_unknown_mode_falls_back_to_blank_white() -> bool:
	var result := SkySocket.build({"mode": "not_a_real_mode"})
	var env: Environment = result["environment"]
	return _check("build(mode=garbage): unknown mode falls back to blank_white, no crash", env.background_mode == Environment.BG_COLOR)


func _test_build_return_shape_matches_painterly_sky() -> bool:
	var sky_result := SkySocket.build({"mode": "blank_white"})
	var painterly_result := PainterlySky.build(PainterlySky.default_descriptor())
	var ok := sky_result.has("environment") and sky_result.has("sun")
	ok = ok and painterly_result.has("environment") and painterly_result.has("sun")
	ok = ok and sky_result["environment"] is Environment and painterly_result["environment"] is Environment
	ok = ok and sky_result["sun"] is DirectionalLight3D and painterly_result["sun"] is DirectionalLight3D
	return _check("build(): return shape ({environment, sun}) matches PainterlySky.build()'s shape exactly", ok)


func _test_sky_gd_untouched_still_builds_normally() -> bool:
	# Regression guard: SkySocket wraps PainterlySky WITHOUT editing sky.gd -- calling PainterlySky
	# directly (as every pre-existing caller does) must still behave exactly as before this file
	# was added.
	var d := PainterlySky.default_descriptor()
	var result := PainterlySky.build(d)
	var env: Environment = result["environment"]
	return _check("PainterlySky.build() called directly is unaffected by SkySocket's existence (primitive untouched)", env.background_mode == Environment.BG_SKY)
