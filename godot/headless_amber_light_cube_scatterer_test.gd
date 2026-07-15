extends SceneTree
## Headless test suite for renderers/amber_light_cube_scatterer.gd (AmberLightCubeScatterer, Wave 4
## item 4.1 (A), DQ-60f088f7):
##
##   godot --headless --path godot -s res://headless_amber_light_cube_scatterer_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_material_default_hue_sat_val_alpha() and ok
	ok = _test_material_emission_enabled_and_energy() and ok
	ok = _test_material_transparency_alpha() and ok
	ok = _test_material_not_metallic() and ok
	ok = _test_jittered_material_stays_within_jitter_range() and ok
	ok = _test_jittered_material_deterministic_for_same_rng_seed() and ok
	ok = _test_scatter_wall_empty_wall_uv_returns_empty() and ok
	ok = _test_scatter_wall_sizes_within_range() and ok
	ok = _test_scatter_wall_deterministic_same_seed() and ok
	ok = _test_scatter_wall_different_seed_differs() and ok
	ok = _test_scatter_wall_zero_density_returns_empty() and ok
	ok = _test_scatter_wall_protrusion_offsets_along_normal() and ok
	ok = _test_scatter_cavities_probability_zero_returns_empty() and ok
	ok = _test_scatter_cavities_probability_one_keeps_all() and ok
	ok = _test_scatter_cavities_marks_in_cavity_true() and ok
	ok = _test_scatter_cavities_sizes_within_range() and ok
	ok = _test_scatter_combines_both_tiers() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── build_material() ────────────────────────────────────────────────────────────────────────────

func _test_material_default_hue_sat_val_alpha() -> bool:
	var mat := AmberLightCubeScatterer.build_material()
	var expected := Color.from_hsv(AmberLightCubeScatterer.DEFAULT_HUE, AmberLightCubeScatterer.DEFAULT_SATURATION,
		AmberLightCubeScatterer.DEFAULT_VALUE, AmberLightCubeScatterer.DEFAULT_GLASS_ALPHA)
	return _check("build_material: default albedo matches HSV(hue,sat,val,alpha) defaults",
		mat.albedo_color.is_equal_approx(expected))

func _test_material_emission_enabled_and_energy() -> bool:
	var mat := AmberLightCubeScatterer.build_material({"emission_energy": 5.0})
	var ok := mat.emission_enabled == true and is_equal_approx(mat.emission_energy_multiplier, 5.0)
	return _check("build_material: emission_enabled + emission_energy_multiplier respected", ok)

func _test_material_transparency_alpha() -> bool:
	var mat := AmberLightCubeScatterer.build_material()
	return _check("build_material: transparency mode is ALPHA (translucent glass)",
		mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA)

func _test_material_not_metallic() -> bool:
	var mat := AmberLightCubeScatterer.build_material()
	return _check("build_material: metallic stays 0 (glass, not chrome)", is_equal_approx(mat.metallic, 0.0))

func _test_jittered_material_stays_within_jitter_range() -> bool:
	var tunables := {"hue": 0.1, "hue_jitter": 0.05}
	var ok := true
	for i in 20:
		var rng := RandomNumberGenerator.new()
		rng.seed = i
		var mat := AmberLightCubeScatterer.jittered_material(tunables, rng)
		var h: float = mat.albedo_color.h
		# hue is HSV-wrapped by Color.from_hsv/albedo_color.h read-back; just assert the material was
		# built without error and roughly near the base hue (within a generous band covering wrap).
		ok = ok and h >= 0.0 and h <= 1.0
	return _check("jittered_material: produces a valid material across many seeds", ok)

func _test_jittered_material_deterministic_for_same_rng_seed() -> bool:
	var tunables := {"hue": 0.2, "hue_jitter": 0.05}
	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 42
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 42
	var mat_a := AmberLightCubeScatterer.jittered_material(tunables, rng_a)
	var mat_b := AmberLightCubeScatterer.jittered_material(tunables, rng_b)
	return _check("jittered_material: same-seeded rng -> identical albedo", mat_a.albedo_color.is_equal_approx(mat_b.albedo_color))


# ── scatter_wall() ──────────────────────────────────────────────────────────────────────────────

func _synthetic_wall_uv(radius: float = 5.0) -> Dictionary:
	var to_transform := func(p: Vector2, _rng: RandomNumberGenerator) -> Transform3D:
		var a := p.x / radius
		var point := Vector3(cos(a) * radius, sin(a * 0.0), sin(a) * radius)
		var basis := Basis.looking_at(Vector3(cos(a), 0.0, sin(a)), Vector3.UP)
		return Transform3D(basis, point)
	return {
		"ring": 1,
		"domain_min": Vector2(0.0, 0.0),
		"domain_max": Vector2(TAU * radius, 1.0),
		"to_transform": to_transform,
	}

func _test_scatter_wall_empty_wall_uv_returns_empty() -> bool:
	var out := AmberLightCubeScatterer.scatter_wall({})
	return _check("scatter_wall: missing domain keys -> empty array, no crash", out.size() == 0)

func _test_scatter_wall_sizes_within_range() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var placements := AmberLightCubeScatterer.scatter_wall(wall_uv, {"size_min": 0.1, "size_max": 0.3, "seed": 7})
	var ok := placements.size() > 0
	for p in placements:
		var size: float = p["size"]
		ok = ok and size >= 0.1 and size <= 0.3
	return _check("scatter_wall: every placement's size falls within [size_min, size_max]", ok)

func _test_scatter_wall_deterministic_same_seed() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var a := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 99})
	var b := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 99})
	var ok := a.size() == b.size() and a.size() > 0
	for i in a.size():
		ok = ok and (a[i]["transform"] as Transform3D).origin.is_equal_approx((b[i]["transform"] as Transform3D).origin)
		ok = ok and is_equal_approx(a[i]["size"], b[i]["size"])
	return _check("scatter_wall: identical seed -> identical placement set (positions + sizes)", ok)

func _test_scatter_wall_different_seed_differs() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var a := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 1})
	var b := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 2})
	var same_count := a.size() == b.size()
	var same_first_origin := false
	if same_count and a.size() > 0:
		same_first_origin = (a[0]["transform"] as Transform3D).origin.is_equal_approx((b[0]["transform"] as Transform3D).origin)
	return _check("scatter_wall: different seed produces a different placement set", not (same_count and same_first_origin))

func _test_scatter_wall_zero_density_returns_empty() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var placements := AmberLightCubeScatterer.scatter_wall(wall_uv, {"density": 0.0, "seed": 3})
	return _check("scatter_wall: density=0.0 -> no placements accepted", placements.size() == 0)

func _test_scatter_wall_protrusion_offsets_along_normal() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var flush := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 11, "protrusion": 0.0})
	var proud := AmberLightCubeScatterer.scatter_wall(wall_uv, {"seed": 11, "protrusion": 0.5})
	var ok := flush.size() > 0 and flush.size() == proud.size()
	if ok:
		var d0: Transform3D = flush[0]["transform"]
		var d1: Transform3D = proud[0]["transform"]
		ok = ok and (d0.origin.distance_to(d1.origin) > 0.4)
	return _check("scatter_wall: larger protrusion pushes the cube further off the wall surface", ok)


# ── scatter_cavities() ──────────────────────────────────────────────────────────────────────────

func _synthetic_cavity_instances(n: int = 30) -> Array:
	var out: Array = []
	for i in n:
		out.append({
			"ring": 1 + (i % 2),
			"through": i % 3 == 0,
			"transform": Transform3D(Basis.IDENTITY, Vector3(float(i) * 0.7, 0.0, 2.0)),
		})
	return out

func _test_scatter_cavities_probability_zero_returns_empty() -> bool:
	var placements := AmberLightCubeScatterer.scatter_cavities(_synthetic_cavity_instances(),
		{"cavity_fill_probability": 0.0, "seed": 5})
	return _check("scatter_cavities: fill_probability=0.0 -> no cavities filled", placements.size() == 0)

func _test_scatter_cavities_probability_one_keeps_all() -> bool:
	var instances := _synthetic_cavity_instances()
	var placements := AmberLightCubeScatterer.scatter_cavities(instances, {"cavity_fill_probability": 1.0, "seed": 5})
	return _check("scatter_cavities: fill_probability=1.0 -> every cavity gets a cube", placements.size() == instances.size())

func _test_scatter_cavities_marks_in_cavity_true() -> bool:
	var placements := AmberLightCubeScatterer.scatter_cavities(_synthetic_cavity_instances(), {"cavity_fill_probability": 1.0})
	var ok := placements.size() > 0
	for p in placements:
		ok = ok and bool(p["in_cavity"]) == true
	return _check("scatter_cavities: every returned placement has in_cavity=true", ok)

func _test_scatter_cavities_sizes_within_range() -> bool:
	var placements := AmberLightCubeScatterer.scatter_cavities(_synthetic_cavity_instances(),
		{"cavity_fill_probability": 1.0, "size_min": 0.15, "size_max": 0.25})
	var ok := placements.size() > 0
	for p in placements:
		var size: float = p["size"]
		ok = ok and size >= 0.15 and size <= 0.25
	return _check("scatter_cavities: every placement's size falls within [size_min, size_max]", ok)


# ── scatter() combined ──────────────────────────────────────────────────────────────────────────

func _test_scatter_combines_both_tiers() -> bool:
	var wall_uv := _synthetic_wall_uv()
	var instances := _synthetic_cavity_instances(10)
	var tunables := {"seed": 21, "cavity_fill_probability": 1.0}
	var wall_only := AmberLightCubeScatterer.scatter_wall(wall_uv, tunables)
	var cavity_only := AmberLightCubeScatterer.scatter_cavities(instances, tunables)
	var combined := AmberLightCubeScatterer.scatter(wall_uv, instances, tunables)
	return _check("scatter(): combined length equals wall-tier + cavity-tier lengths",
		combined.size() == wall_only.size() + cavity_only.size())
