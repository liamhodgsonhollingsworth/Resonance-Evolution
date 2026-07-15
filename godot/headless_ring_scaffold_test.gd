extends SceneTree
## Headless test suite for renderers/ring_scaffold.gd (Wave 2 item 2.1, increment 1):
##
##   godot --headless --path godot -s res://headless_ring_scaffold_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

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
