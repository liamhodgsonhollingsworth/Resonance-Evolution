extends SceneTree
## Headless test suite for renderers/cavity_carver.gd (NonOverlappingCavityCarver, Wave 3 item 3.1,
## DQ-6963c689):
##
##   godot --headless --path godot -s res://headless_cavity_carver_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_carve_empty_wall_map_is_empty() and ok
	ok = _test_shallow_carve_produces_instances_on_the_wall() and ok
	ok = _test_shallow_carve_is_deterministic_by_seed() and ok
	ok = _test_shallow_carve_different_seed_differs() and ok
	ok = _test_shallow_carve_never_flags_through() and ok
	ok = _test_shape_mix_only_uses_known_shapes() and ok
	ok = _test_fixed_shape_is_respected() and ok
	ok = _test_min_spacing_enforced_within_a_ring() and ok
	ok = _test_connect_adjacent_produces_linked_through_pairs() and ok
	ok = _test_connect_adjacent_shared_wall_sampled_once_not_twice() and ok
	ok = _test_connect_adjacent_outermost_ring_has_no_partner() and ok
	ok = _test_connect_adjacent_projects_same_angle_onto_both_rings() and ok
	ok = _test_cavity_cutaway_field_is_through_subset() and ok
	ok = _test_sdf_edits_circle_is_one_sphere() and ok
	ok = _test_sdf_edits_ellipse_is_one_round_box() and ok
	ok = _test_sdf_edits_eye_is_two_intersecting_spheres() and ok
	ok = _test_sdf_edit_actually_carves_wall_field() and ok
	ok = _test_niche_mesh_nonempty_and_within_reach_of_wall() and ok
	ok = _test_through_mesh_connects_near_and_far_transforms() and ok
	ok = _test_composes_with_ring_scaffold_wall_surface_uv_directly() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── helpers ──────────────────────────────────────────────────────────────────────────────────────

## A minimal, cheap 2-ring topology + wall_surface_uv map (real geometry, via RingScaffoldGenerator
## -- the actual node 1 output this carver is designed to consume, not a hand-rolled fake).
func _two_ring_setup(gap: float = 4.0) -> Dictionary:
	var topo := RingScaffoldGenerator.build_topology(2, 5.0, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)
	return {"topo": topo, "wall_by_ring": wall_by_ring}

func _four_ring_setup(gap: float = 4.0) -> Dictionary:
	var topo := RingScaffoldGenerator.build_topology(4, 5.0, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)
	return {"topo": topo, "wall_by_ring": wall_by_ring}


# ── carve() basics ──────────────────────────────────────────────────────────────────────────────

func _test_carve_empty_wall_map_is_empty() -> bool:
	var result := NonOverlappingCavityCarver.carve([], {}, {})
	var ok: bool = (result["cavity_instances"] as Array).is_empty() and (result["cavity_cutaway_field"] as Array).is_empty()
	return _check("carve: empty ring_topology/wall map -> no instances", ok)

func _test_shallow_carve_produces_instances_on_the_wall() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.5, "density": 0.9, "depth": 0.3, "seed": 7})
	var instances: Array = result["cavity_instances"]
	var ok: bool = instances.size() > 0
	for inst in instances:
		var t: Transform3D = inst["transform"]
		# The wall surface sits at ~ring radius +/- a small ellipse extent -- every emitted cavity's
		# world position should be within a modest band of SOME ring's radius (proves placements
		# land on the wall, not off in space).
		var dist_from_origin := Vector2(t.origin.x, t.origin.z).length()
		ok = ok and dist_from_origin > 3.0 and dist_from_origin < 12.0
	return _check("carve: shallow pass on a real 2-ring wall map produces on-wall instances", ok)

func _test_shallow_carve_is_deterministic_by_seed() -> bool:
	var setup := _two_ring_setup()
	var tunables := {"shape": "circle", "min_spacing": 1.5, "density": 0.8, "depth": 0.3, "seed": 42}
	var a := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"], tunables)
	var b := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"], tunables)
	var ia: Array = a["cavity_instances"]
	var ib: Array = b["cavity_instances"]
	var ok: bool = ia.size() == ib.size() and ia.size() > 0
	for i in ia.size():
		var ta: Transform3D = ia[i]["transform"]
		var tb: Transform3D = ib[i]["transform"]
		ok = ok and ta.origin.distance_to(tb.origin) < 1e-5
		ok = ok and ia[i]["shape"] == ib[i]["shape"]
	return _check("carve: same seed + same tunables -> identical instance set", ok)

func _test_shallow_carve_different_seed_differs() -> bool:
	var setup := _two_ring_setup()
	var a := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.5, "density": 0.8, "depth": 0.3, "seed": 1})
	var b := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.5, "density": 0.8, "depth": 0.3, "seed": 2})
	var ia: Array = a["cavity_instances"]
	var ib: Array = b["cavity_instances"]
	var same_count := ia.size() == ib.size()
	var same_positions := same_count
	if same_count:
		for i in ia.size():
			var ta: Transform3D = ia[i]["transform"]
			var tb: Transform3D = ib[i]["transform"]
			if ta.origin.distance_to(tb.origin) > 1e-5:
				same_positions = false
				break
	return _check("carve: different seed -> a different instance set (count or positions)", not (same_count and same_positions))

func _test_shallow_carve_never_flags_through() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.5, "density": 0.8, "depth": 0.1, "seed": 3})
	var ok := true
	for inst in (result["cavity_instances"] as Array):
		ok = ok and inst["through"] == false and inst["connects_to_ring"] == -1
	ok = ok and (result["cavity_cutaway_field"] as Array).is_empty()
	return _check("carve: depth well below connect-adjacent threshold -> nothing flagged through", ok)

func _test_shape_mix_only_uses_known_shapes() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "mix", "min_spacing": 1.2, "density": 0.9, "depth": 0.2, "seed": 9})
	var ok: bool = (result["cavity_instances"] as Array).size() > 0
	var seen: Dictionary = {}
	for inst in (result["cavity_instances"] as Array):
		var s: String = inst["shape"]
		seen[s] = true
		ok = ok and s in NonOverlappingCavityCarver.SHAPES
	return _check("carve: shape=mix only ever emits circle/ellipse/eye", ok)

func _test_fixed_shape_is_respected() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "ellipse", "min_spacing": 1.2, "density": 0.9, "depth": 0.2, "seed": 5})
	var ok: bool = (result["cavity_instances"] as Array).size() > 0
	for inst in (result["cavity_instances"] as Array):
		ok = ok and inst["shape"] == "ellipse"
	return _check("carve: shape=ellipse (fixed) -> every instance is ellipse", ok)

func _test_min_spacing_enforced_within_a_ring() -> bool:
	var setup := _two_ring_setup(3.0)
	var min_spacing := 2.5
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": min_spacing, "density": 1.0, "depth": 0.2, "seed": 11})
	# Group by ring; every pair of SAME-ring instances must be >= min_spacing apart in world space
	# (ScatterComposer's own no-overlap guarantee, proven here end-to-end through this module).
	var by_ring: Dictionary = {}
	for inst in (result["cavity_instances"] as Array):
		var r: int = inst["ring"]
		if not by_ring.has(r):
			by_ring[r] = []
		(by_ring[r] as Array).append(inst)
	var ok := true
	for r in by_ring.keys():
		var group: Array = by_ring[r]
		for i in group.size():
			for j in range(i + 1, group.size()):
				var ta: Transform3D = group[i]["transform"]
				var tb: Transform3D = group[j]["transform"]
				if ta.origin.distance_to(tb.origin) < min_spacing - 0.05:
					ok = false
	return _check("carve: no two same-ring cavities closer than min_spacing", ok)


# ── FM-4 / E4 cross-ring coordination ──────────────────────────────────────────────────────────

func _test_connect_adjacent_produces_linked_through_pairs() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.0, "density": 1.0, "depth": 1.0, "seed": 21})
	var instances: Array = result["cavity_instances"]
	var through: Array = []
	for inst in instances:
		if inst["through"]:
			through.append(inst)
	var ok: bool = through.size() > 0 and through.size() % 2 == 0
	# Every "through" instance's connects_to_ring must point at a partner that ALSO exists in
	# `through`, on the correct ring, with the matching link back -- joined by `pair_id` (the real
	# unique key; `seed` is deliberately NOT used here, see the NOTE in cavity_carver.gd on why the
	# whole owner-pass shares one ScatterComposer run seed).
	var by_ring_pair: Dictionary = {}
	for inst in through:
		by_ring_pair["%d_%s" % [int(inst["ring"]), String(inst["pair_id"])]] = inst
	var pair_ids_seen: Dictionary = {}
	for inst in through:
		ok = ok and String(inst["pair_id"]) != ""
		pair_ids_seen[String(inst["pair_id"])] = true
		var partner_key := "%d_%s" % [int(inst["connects_to_ring"]), String(inst["pair_id"])]
		ok = ok and by_ring_pair.has(partner_key)
		if by_ring_pair.has(partner_key):
			var partner: Dictionary = by_ring_pair[partner_key]
			ok = ok and int(partner["connects_to_ring"]) == int(inst["ring"])
	# Exactly 2 instances per pair_id (never a stray/duplicate join).
	ok = ok and pair_ids_seen.size() * 2 == through.size()
	return _check("carve: depth=1.0 (connect_adjacent) -> linked through-pairs (via pair_id), each with a real reciprocal partner", ok)

func _test_connect_adjacent_shared_wall_sampled_once_not_twice() -> bool:
	# Regression guard for FM-4 itself: run carve() on the 2-ring setup twice, once normally and
	# once after swapping ring 1 and ring 2's positions in `ring_topology` (adjacency data is
	# equivalent either way) -- the OWNER of the shared wall is decided by adjacency (`adjacent_out`
	# following the lower ring index), not by array order, so the through-pair COUNT must match.
	var setup := _two_ring_setup()
	var tunables := {"shape": "circle", "min_spacing": 1.0, "density": 1.0, "depth": 1.0, "seed": 33}
	var a := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"], tunables)
	var reordered_topo: Array = [setup["topo"][1], setup["topo"][0]]
	var b := NonOverlappingCavityCarver.carve(reordered_topo, setup["wall_by_ring"], tunables)
	var through_a := 0
	for inst in (a["cavity_instances"] as Array):
		if inst["through"]:
			through_a += 1
	var through_b := 0
	for inst in (b["cavity_instances"] as Array):
		if inst["through"]:
			through_b += 1
	var ok: bool = through_a > 0 and through_a == through_b
	return _check("carve: shared wall carved ONCE regardless of ring_topology array order (FM-4 owner is adjacency-driven)", ok)

func _test_connect_adjacent_outermost_ring_has_no_partner() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.0, "density": 1.0, "depth": 1.0, "seed": 44})
	var ok := true
	for inst in (result["cavity_instances"] as Array):
		if int(inst["ring"]) == 2 and not inst["through"]:
			# ring 2 (outermost, adjacent_out == -1) may still carry non-through niches on its own
			# outward springline (nothing to connect to there) -- just must never claim through=true
			# with connects_to_ring pointing past the topology.
			ok = ok and int(inst["connects_to_ring"]) == -1
	return _check("carve: outermost ring's own outward springline never fabricates a through-connection", ok)

func _test_connect_adjacent_projects_same_angle_onto_both_rings() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.2, "density": 1.0, "depth": 1.0, "seed": 55})
	var ok := true
	var checked := 0
	for inst in (result["cavity_instances"] as Array):
		if not inst["through"] or int(inst["ring"]) != 1:
			continue
		# Find its ring-2 partner by pair_id (the real unique join key -- NOT `seed`, which is
		# constant across a whole owner-pass; see the NOTE in cavity_carver.gd) and confirm both
		# world positions share (approximately) the same angle around the world Y axis -- the
		# geometric basis of the FM-4 fix.
		for other in (result["cavity_instances"] as Array):
			if other["through"] and int(other["ring"]) == 2 and String(other["pair_id"]) == String(inst["pair_id"]):
				var t1: Transform3D = inst["transform"]
				var t2: Transform3D = other["transform"]
				var a1 := atan2(t1.origin.z, t1.origin.x)
				var a2 := atan2(t2.origin.z, t2.origin.x)
				var diff := absf(angle_difference(a1, a2))
				ok = ok and diff < 0.05
				checked += 1
	ok = ok and checked > 0
	return _check("carve: a linked through-pair sits at the SAME world angle on both rings", ok)

func _test_cavity_cutaway_field_is_through_subset() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.0, "density": 1.0, "depth": 1.0, "seed": 66})
	var instances: Array = result["cavity_instances"]
	var cutaway: Array = result["cavity_cutaway_field"]
	var through_count := 0
	for inst in instances:
		if inst["through"]:
			through_count += 1
	var ok: bool = cutaway.size() == through_count and cutaway.size() > 0
	for inst in cutaway:
		ok = ok and inst["through"] == true
	return _check("carve: cavity_cutaway_field is exactly the through-flagged subset of cavity_instances", ok)


# ── SDF edit-list composition ──────────────────────────────────────────────────────────────────

func _test_sdf_edits_circle_is_one_sphere() -> bool:
	var t := Transform3D(Basis.IDENTITY, Vector3(3.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	var edits: Array = NonOverlappingCavityCarver._sdf_edits("circle", t, 0.8, 1.0, rng)
	var ok: bool = edits.size() == 1 and edits[0]["shape"] == "sphere" and edits[0]["format"] == SDF.EDIT_FORMAT
	ok = ok and edits[0]["op"] == "subtract"
	return _check("_sdf_edits: circle -> exactly one sphere subtract edit, correctly tagged", ok)

func _test_sdf_edits_ellipse_is_one_round_box() -> bool:
	var t := Transform3D(Basis.IDENTITY, Vector3(3.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	var edits: Array = NonOverlappingCavityCarver._sdf_edits("ellipse", t, 0.8, 1.0, rng)
	var ok: bool = edits.size() == 1 and edits[0]["shape"] == "round_box"
	var half_extents: Array = edits[0]["params"]["half_extents"]
	ok = ok and float(half_extents[0]) != float(half_extents[1])  # genuinely non-circular footprint
	return _check("_sdf_edits: ellipse -> one round_box edit with a non-uniform (elliptical) footprint", ok)

func _test_sdf_edits_eye_is_two_intersecting_spheres() -> bool:
	var t := Transform3D(Basis.IDENTITY, Vector3(3.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	var edits: Array = NonOverlappingCavityCarver._sdf_edits("eye", t, 0.8, 1.0, rng)
	var ok: bool = edits.size() == 2
	ok = ok and edits[0]["shape"] == "sphere" and edits[1]["shape"] == "sphere"
	ok = ok and edits[1]["op"] == "intersect"
	var pos_a: Array = edits[0]["transform"]["position"]
	var pos_b: Array = edits[1]["transform"]["position"]
	var offset := Vector3(pos_a[0], pos_a[1], pos_a[2]).distance_to(Vector3(pos_b[0], pos_b[1], pos_b[2]))
	ok = ok and offset > 0.01  # the two spheres are genuinely offset (vesica construction, not coincident)
	return _check("_sdf_edits: eye -> two offset spheres composed via CSG intersect (vesica/almond)", ok)

func _test_sdf_edit_actually_carves_wall_field() -> bool:
	# End-to-end correctness: append a circle cavity's edit(s) after a big "wall" box edit and
	# confirm SDF.field_distance actually reads as CARVED (positive/outside) at the cavity center,
	# where the un-carved wall alone would read solid (negative/inside).
	var cavity_center := Vector3(2.0, 0.0, 0.0)
	var t := Transform3D(Basis.IDENTITY, cavity_center)
	var rng := RandomNumberGenerator.new()
	var edits: Array = NonOverlappingCavityCarver._sdf_edits("circle", t, 1.0, 0.5, rng)
	var wall_edit := {
		"format": SDF.EDIT_FORMAT, "shape": "box", "op": "add", "blend": 0.0,
		"transform": {"position": [0.0, 0.0, 0.0], "scale": 1.0},
		"params": {"half_extents": [5.0, 5.0, 5.0]}, "material": {},
	}
	var full_list: Array = [wall_edit]
	for e in edits:
		full_list.append(e)
	var before := SDF.field_distance([wall_edit], cavity_center)
	var after := SDF.field_distance(full_list, cavity_center)
	var ok: bool = before < 0.0 and after > before
	return _check("_sdf_edits: appended after a base wall solid, SDF.field_distance reads carved (less solid) at the cavity center", ok)


# ── carved geometry (direct parametric mesh, not CSG/voxel) ──────────────────────────────────────

func _test_niche_mesh_nonempty_and_within_reach_of_wall() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.5, "density": 0.9, "depth": 0.3, "seed": 77})
	var instances: Array = result["cavity_instances"]
	var ok: bool = instances.size() > 0
	for inst in instances:
		var mesh: Mesh = inst["mesh"]
		ok = ok and mesh != null and mesh.get_surface_count() > 0
		var aabb := mesh.get_aabb()
		ok = ok and aabb.size.length() > 0.01
	return _check("carve: every shallow-niche cavity_instance carries a real, non-degenerate Mesh", ok)

func _test_through_mesh_connects_near_and_far_transforms() -> bool:
	var setup := _two_ring_setup()
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "circle", "min_spacing": 1.2, "density": 1.0, "depth": 1.0, "seed": 88})
	var found := false
	var ok := true
	for inst in (result["cavity_instances"] as Array):
		if inst["through"]:
			found = true
			var mesh: Mesh = inst["mesh"]
			ok = ok and mesh != null and mesh.get_surface_count() > 0
			var aabb := mesh.get_aabb()
			# A through-passage spans the gap between two ring walls -- its bounding box should be
			# noticeably larger than a single shallow niche's (sanity, not exact geometry).
			ok = ok and aabb.size.length() > 0.3
	ok = ok and found
	return _check("carve: through-passage cavity_instances carry a real lofted Mesh spanning both walls", ok)


# ── direct composition with RingScaffoldGenerator (the actual upstream node) ─────────────────────

func _test_composes_with_ring_scaffold_wall_surface_uv_directly() -> bool:
	var setup := _four_ring_setup(3.5)
	var result := NonOverlappingCavityCarver.carve(setup["topo"], setup["wall_by_ring"],
		{"shape": "mix", "min_spacing": 1.3, "density": 0.7, "depth": 1.0, "seed": 101})
	var instances: Array = result["cavity_instances"]
	var ok: bool = instances.size() > 0
	var rings_seen: Dictionary = {}
	for inst in instances:
		rings_seen[int(inst["ring"])] = true
	# 4 rings, fully connected chain (1-2, 2-3, 3-4) -- expect cavities attributed across every ring.
	ok = ok and rings_seen.size() == 4
	return _check("carve: composes directly with RingScaffoldGenerator.build_topology + wall_surface_uv across 4 rings", ok)
