extends SceneTree
## Headless test suite for renderers/ring_scaffold.gd (Wave 2 item 2.1, increments 1 + 2):
##
##   godot --headless --path godot -s res://headless_ring_scaffold_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.
##
## Increment 2 (DQ-e9516770) added: wall_surface_uv (mesh UVs + the ScatterComposer-compatible
## placement domain), dome_apex_height roof convergence, wedge_world_center/wedge_lod_tier
## (DetailField.DetailLODTracker wiring), export_wedge_chunks_glb (GLTFDocument export). Every
## increment-1 test above is UNCHANGED and must keep passing — that's the backward-compat proof.

func _initialize() -> void:
	var ok := true
	ok = _test_topology_ring_count_and_indexing() and ok
	ok = _test_topology_radius_spacing_matches_gap() and ok
	ok = _test_topology_single_elevation_throughout() and ok
	ok = _test_topology_adjacency_endpoints() and ok
	ok = _test_topology_adjacency_middle_ring() and ok
	ok = _test_topology_clamps_degenerate_inputs() and ok
	ok = _test_wedge_chunks_segment_count() and ok
	ok = _test_wedge_chunks_cover_full_circle() and ok
	ok = _test_wedge_chunks_carry_ring_fields_and_hallway_width() and ok
	ok = _test_wedge_chunks_arc_indexing_matches_chunk_lifecycle() and ok
	ok = _test_wedge_mesh_is_nonempty() and ok
	ok = _test_wedge_mesh_radial_bounds() and ok
	ok = _test_wedge_mesh_vertical_bounds_respect_elevation() and ok
	ok = _test_wedge_mesh_extreme_wall_thickness_clamps_not_crashes() and ok
	ok = _test_build_top_level_shape() and ok
	ok = _test_build_mesh_count_matches_chunks() and ok
	# -- increment 2 --
	ok = _test_wedge_mesh_carries_real_uvs() and ok
	ok = _test_wall_surface_uv_domain_shape() and ok
	ok = _test_wall_surface_uv_to_transform_matches_mesh_geometry() and ok
	ok = _test_wall_surface_uv_composes_with_scatter_composer() and ok
	ok = _test_dome_apex_height_sentinel_matches_plain_ellipse() and ok
	ok = _test_dome_apex_height_converges_shells_at_crown() and ok
	ok = _test_dome_apex_height_leaves_floor_half_untouched() and ok
	ok = _test_build_emits_wall_surface_uv_per_ring() and ok
	ok = _test_wedge_world_center_matches_expected_position() and ok
	ok = _test_wedge_lod_tier_near_far_transitions() and ok
	ok = _test_export_wedge_chunks_glb_writes_valid_files() and ok
	ok = _test_export_mesh_to_file_rejects_null_mesh() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


# ── build_topology ───────────────────────────────────────────────────────────────────────────────

func _test_topology_ring_count_and_indexing() -> bool:
	var topo := RingScaffoldGenerator.build_topology(5, 4.0, 3.0, 0.0)
	var ok := topo.size() == 5
	for i in topo.size():
		ok = ok and int(topo[i]["ring"]) == i + 1   # ring 0 (center) is never emitted
	return _check("build_topology: ring_count=5 -> 5 entries, indices 1..5 (ring 0 never emitted)", ok)

func _test_topology_radius_spacing_matches_gap() -> bool:
	var topo := RingScaffoldGenerator.build_topology(4, 10.0, 2.5, 0.0)
	var ok: bool = float(topo[0]["radius"]) == 10.0
	for i in range(1, topo.size()):
		var delta: float = float(topo[i]["radius"]) - float(topo[i - 1]["radius"])
		ok = ok and abs(delta - 2.5) < 1e-5
	return _check("build_topology: radius_start=10, gap=2.5 -> radii 10,12.5,15,17.5 (spacing == gap)", ok)

func _test_topology_single_elevation_throughout() -> bool:
	# Q2 (elevation variance) resolved live: single elevation throughout — every ring shares the
	# same elevation value, regardless of ring index.
	var topo := RingScaffoldGenerator.build_topology(6, 4.0, 3.0, 7.5)
	var ok := true
	for ring_data in topo:
		ok = ok and float(ring_data["elevation"]) == 7.5
	return _check("build_topology: every ring carries the SAME elevation (Q2: single elevation)", ok)

func _test_topology_adjacency_endpoints() -> bool:
	var topo := RingScaffoldGenerator.build_topology(4, 4.0, 3.0, 0.0)
	var first: Dictionary = topo[0]
	var last: Dictionary = topo[topo.size() - 1]
	return _check("build_topology: innermost ring has adjacent_in=-1, outermost has adjacent_out=-1",
		int(first["adjacent_in"]) == -1 and int(last["adjacent_out"]) == -1)

func _test_topology_adjacency_middle_ring() -> bool:
	var topo := RingScaffoldGenerator.build_topology(5, 4.0, 3.0, 0.0)
	var mid: Dictionary = topo[2]  # ring 3 of 5
	return _check("build_topology: a middle ring's adjacency points at its true neighbors (2 and 4)",
		int(mid["ring"]) == 3 and int(mid["adjacent_in"]) == 2 and int(mid["adjacent_out"]) == 4)

func _test_topology_clamps_degenerate_inputs() -> bool:
	var topo := RingScaffoldGenerator.build_topology(0, -5.0, -1.0, 0.0)
	var ok := topo.size() == 1  # ring_count clamps to >= 1
	ok = ok and float(topo[0]["radius"]) > 0.0  # radius_start/gap clamp to small positive minimums
	return _check("build_topology: degenerate inputs (0 rings, negative radius/gap) clamp, never crash/empty", ok)


# ── wedge_chunks ─────────────────────────────────────────────────────────────────────────────────

func _test_wedge_chunks_segment_count() -> bool:
	var topo := RingScaffoldGenerator.build_topology(3, 4.0, 3.0, 0.0)
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 30.0, 3.0)  # 360/30 = 12 segments/ring
	return _check("wedge_chunks: 3 rings * 12 segments (segment_arc_deg=30) = 36 chunks",
		chunks.size() == 36)

func _test_wedge_chunks_cover_full_circle() -> bool:
	var topo := RingScaffoldGenerator.build_topology(1, 4.0, 3.0, 0.0)
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 40.0, 3.0)  # 360/40 = 9 segments
	var ok := chunks.size() == 9
	# angle_end of one wedge == angle_start of the next, and the LAST wedge's end reaches 360.
	for i in range(1, chunks.size()):
		ok = ok and abs(float(chunks[i]["angle_start_deg"]) - float(chunks[i - 1]["angle_end_deg"])) < 1e-5
	ok = ok and abs(float(chunks[chunks.size() - 1]["angle_end_deg"]) - 360.0) < 1e-5
	ok = ok and abs(float(chunks[0]["angle_start_deg"]) - 0.0) < 1e-5
	return _check("wedge_chunks: wedges tile the full 360 degrees with no gaps/overlaps", ok)

func _test_wedge_chunks_carry_ring_fields_and_hallway_width() -> bool:
	var topo := RingScaffoldGenerator.build_topology(2, 5.0, 4.0, 1.5)
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 90.0, 4.0)
	var ok := true
	for c in chunks:
		var ring_index: int = int(c["ring"])
		var expected_radius: float = 5.0 + 4.0 * float(ring_index - 1)
		ok = ok and abs(float(c["radius"]) - expected_radius) < 1e-5
		ok = ok and float(c["elevation"]) == 1.5
		ok = ok and float(c["hallway_width"]) == 4.0
	return _check("wedge_chunks: each chunk carries its ring's radius/elevation + the hallway_width (gap)", ok)

func _test_wedge_chunks_arc_indexing_matches_chunk_lifecycle() -> bool:
	# wedge_chunks' arc indexing (0..segments-1, 0 at angle 0, increasing with angle) must match
	# ChunkLifecycleManager.ring_key_fn's own indexing so a chunk key from that manager maps 1:1
	# onto a wedge here (Wave 1 item 1.3, this engine's sibling shared primitive). This composes
	# EXACTLY when radius_start == gap (both conventions then agree ring N's radius == gap * N) —
	# a caller wiring the two together in practice would choose exactly that configuration.
	var gap := 3.0
	var topo := RingScaffoldGenerator.build_topology(1, gap, gap, 0.0)  # radius_start == gap
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 20.0, gap)  # 18 segments/ring
	var fn := ChunkLifecycleManager.ring_key_fn(gap, 20.0, 0, 0)
	# A world position at radius == gap (ring 1), angle ~5 deg -> should land in wedge arc 0.
	var pos := Vector3(gap * cos(deg_to_rad(5.0)), 0.0, gap * sin(deg_to_rad(5.0)))
	var keys: Array = fn.call(pos)
	var key: Dictionary = keys[0]
	var matching_chunk = null
	for c in chunks:
		if int(c["ring"]) == int(key["ring"]) and int(c["arc"]) == int(key["arc"]):
			matching_chunk = c
			break
	return _check("wedge_chunks: ring+arc indexing matches ChunkLifecycleManager.ring_key_fn's " +
		"indexing for the same position when radius_start==gap (ring=%s arc=%s)" %
		[key.get("ring"), key.get("arc")], matching_chunk != null)


# ── build_wedge_mesh ─────────────────────────────────────────────────────────────────────────────

func _vertex_positions(mesh: Mesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			out.append_array(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array)
	return out

func _test_wedge_mesh_is_nonempty() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 15.0,
		"radius": 4.0, "elevation": 0.0, "hallway_width": 3.0}
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
	var verts := _vertex_positions(mesh)
	return _check("build_wedge_mesh: produces a non-empty triangle mesh (%d vertices)" % verts.size(),
		verts.size() > 0 and verts.size() % 3 == 0)

func _test_wedge_mesh_radial_bounds() -> bool:
	# radius=10, hallway_width=4 -> corridor spans roughly [8, 12] in the XZ-plane radial distance
	# from the world origin (outer ellipse extent == hallway_width/2 either side of the centerline).
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": 0.0, "hallway_width": 4.0}
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 10, 3)
	var verts := _vertex_positions(mesh)
	var min_r := INF
	var max_r := -INF
	for v in verts:
		var r := Vector2(v.x, v.z).length()
		min_r = minf(min_r, r)
		max_r = maxf(max_r, r)
	var ok := min_r > 10.0 - 2.0 - 0.5 and max_r < 10.0 + 2.0 + 0.5 and max_r > min_r
	return _check("build_wedge_mesh: radial extent stays within the expected hallway_width envelope " +
		"(min_r=%.2f max_r=%.2f, radius=10 +/-2)" % [min_r, max_r], ok)

func _test_wedge_mesh_vertical_bounds_respect_elevation() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 6.0, "elevation": 5.0, "hallway_width": 3.0}
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.2, 1.0)  # ellipse_ratio=1 -> hh == hw
	var verts := _vertex_positions(mesh)
	var min_y := INF
	var max_y := -INF
	for v in verts:
		min_y = minf(min_y, v.y)
		max_y = maxf(max_y, v.y)
	# hallway_width=3 -> hw_outer=1.5, ellipse_ratio=1 -> hh_outer=1.5; centered on elevation=5.
	var ok := min_y > 5.0 - 1.5 - 0.1 and max_y < 5.0 + 1.5 + 0.1 and min_y < 5.0 and max_y > 5.0
	return _check("build_wedge_mesh: vertical extent is centered on chunk.elevation, not world Y=0 " +
		"(min_y=%.2f max_y=%.2f, elevation=5)" % [min_y, max_y], ok)

func _test_wedge_mesh_extreme_wall_thickness_clamps_not_crashes() -> bool:
	# wall_thickness far exceeding the hallway_width would drive hw_inner/hh_inner negative under
	# the raw formula (hw_outer - wall_thickness) -- build_wedge_mesh clamps both to a small
	# positive minimum instead of producing a degenerate/self-intersecting mesh or crashing.
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": 0.0, "hallway_width": 4.0}
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 100.0, 1.3, 8, 2)  # wall_thickness >> hallway_width
	var verts := _vertex_positions(mesh)
	var all_finite := true
	for v in verts:
		if not (is_finite(v.x) and is_finite(v.y) and is_finite(v.z)):
			all_finite = false
	return _check("build_wedge_mesh: an extreme wall_thickness (>> hallway_width) clamps to a small " +
		"positive interior instead of crashing/producing NaN/Inf geometry (%d vertices, all finite=%s)" %
		[verts.size(), all_finite], verts.size() > 0 and all_finite)


# ── build (top-level) ────────────────────────────────────────────────────────────────────────────

func _test_build_top_level_shape() -> bool:
	var result := RingScaffoldGenerator.build({"ring_count": 3, "segment_arc_deg": 60.0})
	var has_keys := result.has("ring_topology") and result.has("chunks") and result.has("meshes")
	var topo: Array = result.get("ring_topology", [])
	var chunks: Array = result.get("chunks", [])
	return _check("build(): returns {ring_topology, chunks, meshes} with 3 rings / 18 chunks (6 arcs each)",
		has_keys and topo.size() == 3 and chunks.size() == 18)

func _test_build_mesh_count_matches_chunks() -> bool:
	var result := RingScaffoldGenerator.build({"ring_count": 2, "segment_arc_deg": 90.0})
	var chunks: Array = result["chunks"]
	var meshes: Dictionary = result["meshes"]
	var ok := meshes.size() == chunks.size()
	for c in chunks:
		var key := "%d_%d" % [int(c["ring"]), int(c["arc"])]
		ok = ok and meshes.has(key) and meshes[key] is Mesh
	return _check("build(): emits exactly one keyed Mesh per chunk (%d chunks == %d meshes)" %
		[chunks.size(), meshes.size()], ok)


# ── increment 2: wall UV-unwrap ──────────────────────────────────────────────────────────────────

func _test_wedge_mesh_carries_real_uvs() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": 0.0, "hallway_width": 4.0}
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
	var ok := true
	var any_nonzero := false
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		ok = ok and uvs != null and (uvs as PackedVector2Array).size() == verts.size()
		for uv in (uvs as PackedVector2Array):
			if uv != Vector2.ZERO:
				any_nonzero = true
	return _check("build_wedge_mesh: every vertex carries a real UV (ARRAY_TEX_UV present, sized to " +
		"match ARRAY_VERTEX, not all-zero)", ok and any_nonzero)


func _test_wall_surface_uv_domain_shape() -> bool:
	var ring_data := {"ring": 3, "radius": 12.0, "elevation": 2.0, "adjacent_in": 2, "adjacent_out": 4}
	var uv := RingScaffoldGenerator.wall_surface_uv(ring_data, 0.3, 1.3, 3.0)
	var dmin: Vector2 = uv["domain_min"]
	var dmax: Vector2 = uv["domain_max"]
	var ok := int(uv["ring"]) == 3 and dmin == Vector2.ZERO
	ok = ok and abs(dmax.x - TAU * 12.0) < 1e-4 and abs(dmax.y - 1.0) < 1e-9
	ok = ok and (uv["to_transform"] as Callable).is_valid()
	return _check("wall_surface_uv: domain_min=(0,0), domain_max=(2*PI*radius, 1) (ScatterComposer's " +
		"own (domain_min,domain_max) contract), carries a valid to_transform Callable", ok)


func _test_wall_surface_uv_to_transform_matches_mesh_geometry() -> bool:
	# The UV domain's to_transform() and build_wedge_mesh()'s own inner-wall vertices must agree on
	# what "position on the wall" means -- sample to_transform at a known (u,v) and independently
	# recompute the expected point via the SAME formula build_wedge_mesh uses for its inner grid.
	var ring_data := {"ring": 1, "radius": 8.0, "elevation": 1.5, "adjacent_in": -1, "adjacent_out": -1}
	var wall_thickness := 0.3
	var ellipse_ratio := 1.3
	var hallway_width := 4.0
	var uv := RingScaffoldGenerator.wall_surface_uv(ring_data, wall_thickness, ellipse_ratio, hallway_width)
	var to_transform: Callable = uv["to_transform"]
	var rng := RandomNumberGenerator.new()

	var radius := 8.0
	var elevation := 1.5
	var a := 0.7  # an arbitrary angle (radians) around the ring
	var v := 0.2  # an arbitrary normalized cross-section position
	var u := radius * a
	var xform := to_transform.call(Vector2(u, v), rng) as Transform3D

	var theta := v * TAU
	var extents := RingScaffoldGenerator._shell_extents(hallway_width, wall_thickness, ellipse_ratio)
	var hw_inner: float = extents["hw_inner"]
	var hh_inner: float = extents["hh_inner"]
	var radial := Vector3(cos(a), 0.0, sin(a))
	var up := Vector3(0.0, 1.0, 0.0)
	var center := Vector3(cos(a) * radius, elevation, sin(a) * radius)
	var expected := center + radial * (cos(theta) * hw_inner) + up * (sin(theta) * hh_inner)

	var ok := xform.origin.distance_to(expected) < 1e-4
	return _check("wall_surface_uv: to_transform(u,v) lands exactly on the inner-wall point " +
		"build_wedge_mesh's own formula computes for the same (u,v) (delta=%.6f)" %
		[xform.origin.distance_to(expected)], ok)


func _test_wall_surface_uv_composes_with_scatter_composer() -> bool:
	# The stated composition target (DQ-e9516770, plan §2.2): the Wave 3 cavity carver's "unroll to
	# 2D, run Poisson-disk, map back onto the cylinder" should reduce to calling
	# ScatterComposer.sample() with THIS domain unchanged. Prove that call actually works end to end.
	var ring_data := {"ring": 2, "radius": 7.0, "elevation": 0.0, "adjacent_in": 1, "adjacent_out": 3}
	var uv := RingScaffoldGenerator.wall_surface_uv(ring_data)
	var placements := ScatterComposer.sample(
		uv["domain_min"], uv["domain_max"], 1.5, Callable(), 42, "cavity", uv["to_transform"])
	var ok := placements.size() > 0
	for p in placements:
		var origin: Vector3 = p.transform.origin
		ok = ok and is_finite(origin.x) and is_finite(origin.y) and is_finite(origin.z)
		# every placement should sit close to ring radius 7 (within the wall's own thickness band).
		var r := Vector2(origin.x, origin.z).length()
		ok = ok and abs(r - 7.0) < 3.0
	return _check("wall_surface_uv: composes directly with ScatterComposer.sample() (Wave 1 item " +
		"1.1) -- %d finite placements on the ring-2 wall, all within the shell's radial band" %
		[placements.size()], ok)


# ── increment 2: dome_apex_height roof shaping ──────────────────────────────────────────────────

func _test_dome_apex_height_sentinel_matches_plain_ellipse() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": 0.0, "hallway_width": 4.0}
	var default_mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2)
	var explicit_mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2,
		RingScaffoldGenerator.DEFAULT_DOME_APEX_HEIGHT)
	var v1 := _vertex_positions(default_mesh)
	var v2 := _vertex_positions(explicit_mesh)
	var ok := v1.size() == v2.size()
	for i in v1.size():
		ok = ok and v1[i].distance_to(v2[i]) < 1e-6
	return _check("build_wedge_mesh: omitting dome_apex_height == passing the sentinel explicitly " +
		"(byte-for-byte identical geometry, increment-1 behavior unchanged)", ok)


func _test_dome_apex_height_converges_shells_at_crown() -> bool:
	var elevation := 3.0
	var apex := 4.0  # well above the default ellipse's own hh_outer (~1.95), so this proves a real rise
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": elevation, "hallway_width": 3.0}
	# cross_segments=8 samples theta=PI/2 EXACTLY at j=2 (TAU*2/8), so the crown is an exact sample.
	var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2, apex)
	var verts := _vertex_positions(mesh)
	var max_y := -INF
	for v in verts:
		max_y = maxf(max_y, v.y)
	var flat_mesh := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2)  # sentinel, plain ellipse
	var flat_max_y := -INF
	for v in _vertex_positions(flat_mesh):
		flat_max_y = maxf(flat_max_y, v.y)
	var delta_from_apex: float = absf(max_y - (elevation + apex))
	var ok: bool = delta_from_apex < 0.001
	ok = ok and max_y > flat_max_y + 0.5  # actually rose above the plain-ellipse roof
	return _check("build_wedge_mesh: dome_apex_height=4 converges BOTH shells to a single point at " +
		"elevation+apex (max_y=%.3f, expected=%.3f, plain-ellipse max_y=%.3f)" %
		[max_y, elevation + apex, flat_max_y], ok)


func _test_dome_apex_height_leaves_floor_half_untouched() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 30.0,
		"radius": 10.0, "elevation": 0.0, "hallway_width": 4.0}
	var domed := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2, 6.0)
	var flat := RingScaffoldGenerator.build_wedge_mesh(chunk, 0.3, 1.3, 8, 2)
	var vd := _vertex_positions(domed)
	var vf := _vertex_positions(flat)
	# Q2 (single elevation, only ceiling may vary): the lowest point of the cross-section (the floor,
	# theta=3PI/2, sin<0) must be IDENTICAL between the domed and plain-ellipse builds.
	var min_yd := INF
	var min_yf := INF
	for v in vd:
		min_yd = minf(min_yd, v.y)
	for v in vf:
		min_yf = minf(min_yf, v.y)
	var floor_delta: float = absf(min_yd - min_yf)
	var ok: bool = floor_delta < 0.000001
	return _check("build_wedge_mesh: dome_apex_height only reshapes the ceiling -- the floor's " +
		"lowest point is unchanged vs. the plain ellipse (min_y domed=%.4f flat=%.4f), per Q2" %
		[min_yd, min_yf], ok)


func _test_build_emits_wall_surface_uv_per_ring() -> bool:
	var result := RingScaffoldGenerator.build({"ring_count": 3, "segment_arc_deg": 60.0})
	var wall_uv: Dictionary = result.get("wall_surface_uv", {})
	var ok := wall_uv.size() == 3
	for ring_index in [1, 2, 3]:
		ok = ok and wall_uv.has(ring_index) and (wall_uv[ring_index] as Dictionary).has("to_transform")
	return _check("build(): emits wall_surface_uv keyed by ring index, one entry per ring (%d rings)" %
		[wall_uv.size()], ok)


# ── increment 2: DetailField/DetailLODTracker wiring ────────────────────────────────────────────

func _test_wedge_world_center_matches_expected_position() -> bool:
	var chunk := {"ring": 1, "arc": 0, "angle_start_deg": 0.0, "angle_end_deg": 90.0,
		"radius": 5.0, "elevation": 2.0}
	var center := RingScaffoldGenerator.wedge_world_center(chunk)
	# midpoint angle = 45 deg
	var expected := Vector3(cos(deg_to_rad(45.0)) * 5.0, 2.0, sin(deg_to_rad(45.0)) * 5.0)
	return _check("wedge_world_center: returns the world position at the wedge's angular midpoint " +
		"(delta=%.6f)" % [center.distance_to(expected)], center.distance_to(expected) < 1e-4)


func _test_wedge_lod_tier_near_far_transitions() -> bool:
	var chunk := {"ring": 2, "arc": 5, "angle_start_deg": 0.0, "angle_end_deg": 15.0,
		"radius": 10.0, "elevation": 0.0}
	var tracker := DetailField.DetailLODTracker.new()
	var wedge_pos := RingScaffoldGenerator.wedge_world_center(chunk)

	# Unseen wedge, camera FAR away -> stays LOD_FAR, not a swap (matches the documented "unseen
	# starts FAR" default).
	var far_cam := wedge_pos + Vector3(500.0, 0.0, 0.0)
	var r1 := RingScaffoldGenerator.wedge_lod_tier(chunk, far_cam, tracker, 1.0, 20.0)
	var ok := int(r1["tier"]) == DetailField.LOD_FAR and not bool(r1["swapped"])

	# Camera moves close -> swaps to LOD_NEAR.
	var near_cam := wedge_pos + Vector3(1.0, 0.0, 0.0)
	var r2 := RingScaffoldGenerator.wedge_lod_tier(chunk, near_cam, tracker, 1.0, 20.0)
	ok = ok and int(r2["tier"]) == DetailField.LOD_NEAR and bool(r2["swapped"])
	ok = ok and int(tracker.tier_of("2_5")) == DetailField.LOD_NEAR

	# Camera moves far again -> swaps back to LOD_FAR (well past the hysteresis margin).
	var r3 := RingScaffoldGenerator.wedge_lod_tier(chunk, far_cam, tracker, 1.0, 20.0)
	ok = ok and int(r3["tier"]) == DetailField.LOD_FAR and bool(r3["swapped"])
	return _check("wedge_lod_tier: wires DetailField.DetailLODTracker per wedge (item_id matches " +
		"build()'s \"%d_%d\" key convention), tracks near/far swaps as the camera moves", ok)


# ── increment 2: GLB export per chunk ────────────────────────────────────────────────────────────

func _test_export_wedge_chunks_glb_writes_valid_files() -> bool:
	var result := RingScaffoldGenerator.build({"ring_count": 1, "segment_arc_deg": 90.0})  # 4 chunks
	var out_dir := "res://live/test_ring_scaffold_glb_export"
	var errors := RingScaffoldGenerator.export_wedge_chunks_glb(result["meshes"], out_dir)
	var ok := errors.size() == (result["meshes"] as Dictionary).size()
	for key in errors.keys():
		ok = ok and int(errors[key]) == OK
		var path := "%s/wedge_%s.glb" % [out_dir, String(key)]
		ok = ok and FileAccess.file_exists(path)
		if FileAccess.file_exists(path):
			var f := FileAccess.open(path, FileAccess.READ)
			ok = ok and f != null and f.get_length() > 0
	return _check("export_wedge_chunks_glb: writes one non-empty .glb per chunk, all Error==OK " +
		"(%d chunks)" % [errors.size()], ok)


func _test_export_mesh_to_file_rejects_null_mesh() -> bool:
	var err: int = GltfExporter.export_mesh_to_file(null, "res://live/test_ring_scaffold_glb_export/should_not_exist.glb")
	return _check("GltfExporter.export_mesh_to_file: a null Mesh returns an Error, does not crash",
		err != OK)
