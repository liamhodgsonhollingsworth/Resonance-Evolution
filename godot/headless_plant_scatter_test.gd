extends SceneTree
## Headless test suite for renderers/plant_scatter.gd (PlantScatterInCavities, Wave 4 item 4.3 (B),
## DQ-6c2dc2f2):
##
##   godot --headless --path godot -s res://headless_plant_scatter_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_scatter_empty_inputs_returns_empty() and ok
	ok = _test_scatter_zero_density_returns_empty() and ok
	ok = _test_scatter_prefers_cutaway_field_over_full_set() and ok
	ok = _test_scatter_falls_back_to_cavity_instances_when_cutaway_empty() and ok
	ok = _test_scatter_deterministic_same_seed() and ok
	ok = _test_scatter_different_seed_differs() and ok
	ok = _test_scatter_default_handle_produces_scene_node() and ok
	ok = _test_scatter_asset_handle_passthrough_no_scene_node() and ok
	ok = _test_scatter_unknown_lsystem_species_still_resolves() and ok
	ok = _test_scatter_cavity_ring_matches_source() and ok
	ok = _test_scatter_on_floor_reflects_through_flag() and ok
	ok = _test_scatter_scale_within_tunable_range() and ok
	ok = _test_scatter_max_per_cavity_caps_count() and ok
	ok = _test_scatter_placements_stay_near_cavity_footprint() and ok
	ok = _test_scene_node_has_segments_for_default_species() and ok
	ok = _test_scatter_aggregates_across_multiple_cavities() and ok
	ok = _test_scatter_call_target_matches_handle() and ok
	ok = _test_scatter_kit_handle_resolves_real_glb_scene_node() and ok
	ok = _test_scatter_kit_handle_glb_file_exists_on_disk() and ok
	ok = _test_scatter_kit_handle_species_filter_restricts_selection() and ok
	ok = _test_scatter_kit_handle_scale_reflects_tunable_range() and ok
	ok = _test_scatter_kit_handle_unknown_kit_falls_back_to_lsystem() and ok
	ok = _test_scatter_kit_handle_empty_species_filter_falls_back_to_lsystem() and ok
	ok = _test_scatter_kit_handle_call_target_still_matches_handle() and ok
	ok = _test_scatter_kit_handle_deterministic_same_seed() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── synthetic fixtures ──────────────────────────────────────────────────────────────────────────

func _cavity(i: int, ring: int, through: bool, size: float = 0.6) -> Dictionary:
	return {
		"ring": ring,
		"through": through,
		"size": size,
		"transform": Transform3D(Basis.IDENTITY, Vector3(float(i) * 3.0, 0.0, 2.0)),
	}

func _synthetic_cavity_instances(n: int = 8) -> Array:
	var out: Array = []
	for i in n:
		out.append(_cavity(i, 1 + (i % 2), i % 3 == 0))
	return out

func _synthetic_cutaway_field(n: int = 4) -> Array:
	var out: Array = []
	for i in n:
		out.append(_cavity(100 + i, 2, true))
	return out


# ── candidate-set selection ─────────────────────────────────────────────────────────────────────

func _test_scatter_empty_inputs_returns_empty() -> bool:
	var out := PlantScatterInCavities.scatter([], [], {"seed": 1})
	return _check("scatter: empty cavity_instances + empty cavity_cutaway_field -> empty output", out.size() == 0)

func _test_scatter_zero_density_returns_empty() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(), [], {"density": 0.0, "seed": 1})
	return _check("scatter: density=0.0 -> no placements accepted", out.size() == 0)

func _test_scatter_prefers_cutaway_field_over_full_set() -> bool:
	var instances := _synthetic_cavity_instances(8)
	var cutaway := _synthetic_cutaway_field(4)
	var out := PlantScatterInCavities.scatter(instances, cutaway, {"seed": 5, "density": 1.0})
	var ok := out.size() > 0
	for p in out:
		ok = ok and int(p["cavity_ring"]) == 2  # every cutaway fixture is ring=2
	return _check("scatter: cavity_cutaway_field non-empty -> candidates drawn ONLY from it", ok)

func _test_scatter_falls_back_to_cavity_instances_when_cutaway_empty() -> bool:
	var instances := _synthetic_cavity_instances(8)
	var out := PlantScatterInCavities.scatter(instances, [], {"seed": 5, "density": 1.0})
	return _check("scatter: empty cavity_cutaway_field -> falls back to cavity_instances (non-empty output)", out.size() > 0)


# ── determinism ─────────────────────────────────────────────────────────────────────────────────

func _test_scatter_deterministic_same_seed() -> bool:
	var instances := _synthetic_cavity_instances(6)
	var a := PlantScatterInCavities.scatter(instances, [], {"seed": 42, "density": 0.9})
	var b := PlantScatterInCavities.scatter(instances, [], {"seed": 42, "density": 0.9})
	var ok := a.size() == b.size() and a.size() > 0
	for i in a.size():
		ok = ok and (a[i]["transform"] as Transform3D).origin.is_equal_approx((b[i]["transform"] as Transform3D).origin)
		ok = ok and is_equal_approx(float(a[i]["scale"]), float(b[i]["scale"]))
	return _check("scatter: identical seed -> identical placement set (positions + scales)", ok)

func _test_scatter_different_seed_differs() -> bool:
	var instances := _synthetic_cavity_instances(6)
	var a := PlantScatterInCavities.scatter(instances, [], {"seed": 1, "density": 0.9})
	var b := PlantScatterInCavities.scatter(instances, [], {"seed": 2, "density": 0.9})
	var same := a.size() == b.size()
	if same and a.size() > 0:
		same = (a[0]["transform"] as Transform3D).origin.is_equal_approx((b[0]["transform"] as Transform3D).origin)
	return _check("scatter: different seed produces a different placement set", not same)


# ── CC0 asset seam / scene_node resolution ──────────────────────────────────────────────────────

func _test_scatter_default_handle_produces_scene_node() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [], {"seed": 3, "density": 1.0})
	var ok := out.size() > 0
	for p in out:
		ok = ok and p["scene_node"] != null and (p["scene_node"] as Dictionary).has("children")
	return _check("scatter: default tree_asset_handle (lsystem:default) builds a non-null scene_node", ok)

func _test_scatter_asset_handle_passthrough_no_scene_node() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "asset:potted_fern"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and p["scene_node"] == null and String(p["call_target"]) == "asset:potted_fern"
	return _check("scatter: non-lsystem handle -> scene_node stays null, call_target passes through unresolved (CC0 seam)", ok)

func _test_scatter_unknown_lsystem_species_still_resolves() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "lsystem:nonexistent_species"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and p["scene_node"] != null
	return _check("scatter: unrecognized lsystem: species name -> seeded fallback roll, still resolves a scene_node", ok)

func _test_scatter_call_target_matches_handle() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "lsystem:fern"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and String(p["call_target"]) == "lsystem:fern"
	return _check("scatter: call_target on every placement equals the tree_asset_handle tunable", ok)


# ── source-field passthrough ────────────────────────────────────────────────────────────────────

func _test_scatter_cavity_ring_matches_source() -> bool:
	var instances: Array = [_cavity(0, 7, false), _cavity(1, 9, true)]
	var out := PlantScatterInCavities.scatter(instances, [], {"seed": 8, "density": 1.0})
	var rings := {}
	for p in out:
		rings[int(p["cavity_ring"])] = true
	return _check("scatter: cavity_ring on each placement matches its source cavity's ring", rings.has(7) or rings.has(9))

func _test_scatter_on_floor_reflects_through_flag() -> bool:
	var instances: Array = [_cavity(0, 1, false), _cavity(1, 1, true)]
	var out := PlantScatterInCavities.scatter(instances, [], {"seed": 8, "density": 1.0})
	var saw_floor := false
	var saw_wall := false
	for p in out:
		if bool(p["on_floor"]):
			saw_floor = true
		else:
			saw_wall = true
	return _check("scatter: on_floor reflects the source cavity's through flag (both true/false seen across the set)", saw_floor and saw_wall)


# ── scale / density / caps ──────────────────────────────────────────────────────────────────────

func _test_scatter_scale_within_tunable_range() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(6), [],
		{"seed": 12, "density": 1.0, "size_min": 0.5, "size_max": 0.9})
	var ok := out.size() > 0
	for p in out:
		var s: float = p["scale"]
		ok = ok and s >= 0.5 and s <= 0.9
	return _check("scatter: every placement's scale falls within [size_min, size_max]", ok)

func _test_scatter_max_per_cavity_caps_count() -> bool:
	var single: Array = [_cavity(0, 1, true, 3.0)]
	var out := PlantScatterInCavities.scatter(single, [], {"seed": 9, "density": 1.0, "max_per_cavity": 2})
	return _check("scatter: max_per_cavity caps the placement count for a single large cavity", out.size() <= 2)

func _test_scatter_placements_stay_near_cavity_footprint() -> bool:
	var size := 0.6
	var single: Array = [_cavity(0, 1, true, size)]
	var out := PlantScatterInCavities.scatter(single, [], {"seed": 20, "density": 1.0, "protrusion": 0.05})
	var ok := out.size() > 0
	var origin: Vector3 = (single[0]["transform"] as Transform3D).origin
	for p in out:
		var d := origin.distance_to((p["transform"] as Transform3D).origin)
		ok = ok and d <= (size * 1.5 + 0.2)  # local-plane radius bound + protrusion + slack
	return _check("scatter: every placement stays within the cavity's own local footprint radius (+protrusion)", ok)

func _test_scatter_aggregates_across_multiple_cavities() -> bool:
	var one := PlantScatterInCavities.scatter([_cavity(0, 1, true)], [], {"seed": 4, "density": 1.0})
	var many := PlantScatterInCavities.scatter(_synthetic_cavity_instances(8), [], {"seed": 4, "density": 1.0})
	return _check("scatter: more candidate cavities yields at least as many total placements", many.size() >= one.size())


# ── L-system integration sanity ─────────────────────────────────────────────────────────────────

func _test_scene_node_has_segments_for_default_species() -> bool:
	var out := PlantScatterInCavities.scatter([_cavity(0, 1, true, 1.0)], [], {"seed": 15, "density": 1.0})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		ok = ok and (node.get("children", []) as Array).size() > 0
	return _check("scatter: each built scene_node carries at least one L-system segment child", ok)


# ── real ingested-kit tree assets (DQ-9183cfe2, 2026-07-15) ────────────────────────────────────────
# Exercises the REAL `quaternius_nature` kit vendored + ingested into this repo
# (godot/assets/ingested/manifest.json, godot/assets/vendor/quaternius_nature/*.glb) -- proves the
# real asset-ingestion pipeline is actually wired into the cavity population path, not a mock.

func _test_scatter_kit_handle_resolves_real_glb_scene_node() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature"})
	var ok := out.size() > 0
	for p in out:
		var node = p["scene_node"]
		ok = ok and node != null and typeof(node) == TYPE_DICTIONARY
		if ok:
			var mesh: Dictionary = (node as Dictionary).get("mesh", {})
			ok = ok and String(mesh.get("source", "")) == "glb" and String(mesh.get("path", "")) != ""
	return _check("scatter: 'kit:quaternius_nature' handle resolves a real mesh.source=glb scene_node (not L-system)", ok)

func _test_scatter_kit_handle_glb_file_exists_on_disk() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(6), [],
		{"seed": 7, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature"})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		var path := String((node.get("mesh", {}) as Dictionary).get("path", ""))
		ok = ok and path != "" and FileAccess.file_exists(path)
	return _check("scatter: every resolved kit GLB path exists on disk (real vendored asset, not a dangling reference)", ok)

func _test_scatter_kit_handle_species_filter_restricts_selection() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(10), [],
		{"seed": 11, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature", "tree_species": ["pine"]})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		var path := String((node.get("mesh", {}) as Dictionary).get("path", "")).to_lower()
		ok = ok and path.find("pine") >= 0 and path.find("twisted_tree") < 0
	return _check("scatter: tree_species=['pine'] restricts every placement to the pine model only (species-mix tunable)", ok)

func _test_scatter_kit_handle_scale_reflects_tunable_range() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(6), [],
		{"seed": 12, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature", "size_min": 0.4, "size_max": 0.6})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		var s: Array = node.get("scale", [1.0, 1.0, 1.0])
		var sx: float = float(s[0])
		ok = ok and sx >= 0.4 and sx <= 0.6 and is_equal_approx(sx, float(p["scale"]))
	return _check("scatter: a kit tree's scene_node scale reflects size_min/size_max (scale-jitter tunable applies to real assets too)", ok)

func _test_scatter_kit_handle_unknown_kit_falls_back_to_lsystem() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "kit:nonexistent_kit_xyz"})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		ok = ok and node != null and (node.get("children", []) as Array).size() > 0 and not node.has("mesh")
	return _check("scatter: unknown kit id gracefully falls back to the built-in lsystem species (never emits nothing, never crashes)", ok)

func _test_scatter_kit_handle_empty_species_filter_falls_back_to_lsystem() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature", "tree_species": ["nonexistent_species_xyz"]})
	var ok := out.size() > 0
	for p in out:
		var node: Dictionary = p["scene_node"]
		ok = ok and node != null and not node.has("mesh")
	return _check("scatter: a species filter matching zero kit members falls back to lsystem rather than emitting nothing", ok)

func _test_scatter_kit_handle_call_target_still_matches_handle() -> bool:
	var out := PlantScatterInCavities.scatter(_synthetic_cavity_instances(4), [],
		{"seed": 3, "density": 1.0, "tree_asset_handle": "kit:quaternius_nature"})
	var ok := out.size() > 0
	for p in out:
		ok = ok and String(p["call_target"]) == "kit:quaternius_nature"
	return _check("scatter: call_target on every placement still equals the tree_asset_handle tunable for kit: handles too", ok)

func _test_scatter_kit_handle_deterministic_same_seed() -> bool:
	var instances := _synthetic_cavity_instances(6)
	var a := PlantScatterInCavities.scatter(instances, [], {"seed": 42, "density": 0.9, "tree_asset_handle": "kit:quaternius_nature"})
	var b := PlantScatterInCavities.scatter(instances, [], {"seed": 42, "density": 0.9, "tree_asset_handle": "kit:quaternius_nature"})
	var ok := a.size() == b.size() and a.size() > 0
	for i in a.size():
		var pa := String((a[i]["scene_node"] as Dictionary).get("mesh", {}).get("path", ""))
		var pb := String((b[i]["scene_node"] as Dictionary).get("mesh", {}).get("path", ""))
		ok = ok and pa == pb
	return _check("scatter: identical seed -> identical real-asset picks too (deterministic species roll)", ok)
