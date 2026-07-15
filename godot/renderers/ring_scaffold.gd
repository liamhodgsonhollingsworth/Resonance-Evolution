class_name RingScaffoldGenerator
extends RefCounted
## RingScaffoldGenerator — node 1 ("Scaffolding tier") of
## notes/planning/underground_halls_plan_2026_07_14.md §4, Wave 2 item 2.1 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5. Circular-spline extrusion of an
## elliptical-shell hallway cross-section, chunked into arc-segment wedges (plan §2.1).
##
## TOPOLOGY, per Liam's LIVE-CONFIRMED answers (underground_halls_plan_2026_07_14.md §11/§12,
## Discord #dev msgs 1526685861260034079 / 1526686319802323024, 2026-07-14T20:24-20:26Z):
##   Q1 = Option A — flat concentric rings (not a domed multi-tier envelope).
##   Q2 = single elevation — one floor level throughout; only ceiling/roof height may vary.
## Wave 1.5's topology-prototype-and-score gate existed to choose between competing topologies;
## that choice is already made, so this increment builds the confirmed topology directly.
##
## INCREMENT 1 (this file): the ring topology DATA (`build_topology`), the arc-segment wedge
## CHUNKING (`wedge_chunks`), and a real extruded hollow elliptical-shell hallway MESH per wedge
## (`build_wedge_mesh`) — a genuinely renderable/testable first slice. Per the no-auto-generalization
## discipline, explicitly DEFERRED to a later increment (named here so it is a documented decision,
## not a silent omission): `wall_surface_uv` (the unrolled cylindrical UV strip the cavity carver,
## plan §2.2, consumes downstream) and `dome_apex_height`-driven roof-convergence shaping (both
## named in node 1's full spec, neither required for a first renderable slice under the now-flat,
## single-elevation topology).
##
## INCREMENT 2 (this file, additive — every increment-1 default/signature/return-shape stays
## unchanged; nothing above this comment was rewritten): the four items deferred above, plus the
## per-wedge LOD wiring node 1's `detail_field` input port names. DQ-e9516770:
##   (a) `wall_surface_uv()` — per-ring unrolled-cylinder UV-strip DOMAIN descriptor, shaped to
##       plug directly into `ScatterComposer.sample()`'s own `domain_min`/`domain_max`/`to_transform`
##       contract (renderers/scatter_composer.gd, Wave 1 item 1.1) — this IS the seam the Wave 3
##       cavity carver (plan §2.2) consumes, built now so that build is pure wiring later. The
##       "wall" unrolled is the INNER shell surface (the corridor-interior-facing boundary — what a
##       person walking the hallway sees, and where niches/alcoves per §2.2 get carved FROM), a
##       cylinder in (arc-length, cross-section-angle) exactly per §2.2's "topologically a cylinder"
##       framing. `build_wedge_mesh` below also now writes real per-vertex UVs onto BOTH shell walls
##       using this SAME (u, v) convention, so a texture and the carver's placement domain agree.
##   (b) `dome_apex_height` on `build_wedge_mesh()` — roof/ceiling convergence: Liam's own words
##       (quoted in the topology-answers doc, `notes/planning/underground_halls_plan_2026_07_14.md`
##       §5 Q1) describe "two shells... converge at a point near the roof." Q2's live answer (single
##       elevation, only ceiling may vary) confirmed this applies to ceiling shape only, not floor
##       elevation — so the convergence blend below only ever touches the UPPER half of the cross-
##       section (`sin(theta) > 0`), leaving the floor half exactly as increment 1 built it.
##       Sentinel-gated (`< 0.0` = disabled, the exact increment-1 ellipse) so every increment-1
##       default call site is byte-for-byte unchanged.
##   (c) `RingScaffoldGenerator.export_wedge_chunks_glb()` — per-chunk GLB export, node 1's
##       "hallway_shell_mesh (chunked GLB, one per arc-segment)" output shape. Reuses
##       `GltfExporter.export_mesh_to_file()` (renderers/gltf_exporter.gd, the SPEC-754
##       Blender-vs-engine-hybrid decision's chosen export mechanism) — a small ADDITIVE sibling
##       entry point on that same file for a raw procedural `Mesh` producer (this generator never
##       goes through GraphRuntime's renderer-neutral `scene_node` descriptors, so the existing
##       `export_to_file(roots, ...)` entry point does not apply directly; the new entry point reuses
##       the identical GLTFDocument/GLTFState primitives, not a second implementation).
##   (d) `wedge_world_center()` / `wedge_lod_tier()` — the `detail_field` input port's actual wiring,
##       composing `DetailField.DetailLODTracker` (renderers/detail_field.gd, Wave 1 item 1.2, PR
##       #188) with a wedge's world position. Per this file's own increment-1 design note above ("this
##       generator only emits the real geometry; it never decides LOD tier itself"), this is CALLER-
##       SIDE wiring a scene driver calls once per visible wedge per frame — `RingScaffoldGenerator`
##       still never owns tracker state itself.
##
## `gap` is "the headline tunable Liam named explicitly" (plan §4: hallway width). Here it plays
## TWO roles by design, both natural for concentric hallway rings packed edge-to-edge: (1) the
## radial spacing between consecutive ring centerlines, and (2) each ring's own walkable corridor
## width — i.e. rings are packed so ring N's corridor exactly spans the gap between ring N and
## ring N+1's centerlines. This also means `gap` composes directly with
## ChunkLifecycleManager.ring_key_fn's own `ring_spacing` parameter (Wave 1 item 1.3, this engine's
## sibling shared primitive) — the SAME number keys chunk streaming and generates geometry.
##
## Pure DATA (`build_topology`/`wedge_chunks` return plain Arrays of Dictionaries) plus a Godot
## `Mesh` resource out per wedge (`build_wedge_mesh`) — same shape as `godot_scene_renderer.gd`'s
## own ArrayMesh builders (POSITION + NORMAL, no UVs yet; UVs are the deferred `wall_surface_uv`
## work above). `detail_field` (node 1's spec names it as an input, "LOD budget in") composes
## downstream through `DetailField`/`DetailField.DetailLODTracker` (Wave 1 item 1.2): a caller
## reads a wedge's detail budget at its world position and feeds it to a tracker to decide whether
## THIS wedge's mesh should be live-instanced (real geometry, LOD_NEAR) or swapped for a baked
## impostor (LOD_FAR) — this generator only emits the real geometry; it never decides LOD tier
## itself (same separation of concerns the sibling primitives hold).

const DEFAULT_GAP := 3.0                 # hallway width / ring-to-ring spacing, plan §4 range 1-8m
const DEFAULT_RING_COUNT := 6            # plan §4 range 1-20
const DEFAULT_RADIUS_START := 4.0
const DEFAULT_WALL_THICKNESS := 0.3
const DEFAULT_ELLIPSE_RATIO := 1.3       # shell cross-section height:width proportion
const DEFAULT_SEGMENT_ARC_DEG := 15.0    # plan §4 range 5-45
const DEFAULT_ELEVATION := 0.0           # single elevation throughout (Q2) — every ring shares this
const DEFAULT_DOME_APEX_HEIGHT := -1.0   # sentinel: < 0 disables roof convergence (plain ellipse,
                                          # byte-for-byte increment-1 behavior); >= 0 = absolute apex
                                          # Y offset above the ring's elevation, plan §4's tunable


## Build the per-ring topology DATA. Ring indices run 1..ring_count (ring 0 is the center, never
## emitted — matching ChunkLifecycleManager.ring_key_fn's own convention, so a chunk key from that
## manager maps directly onto a ring here). Each entry:
##   {"ring": int, "radius": float, "elevation": float, "adjacent_in": int, "adjacent_out": int}
## `adjacent_in`/`adjacent_out` are -1 at the innermost/outermost ring — this is the per-ring
## adjacency node 1's spec names ("so the cavity carver knows which walls are shared between
## adjacent hallways"). `elevation` is the SAME value for every ring (Q2: single elevation),
## carried per-ring anyway so a caller reading `ring_topology` never needs a separate lookup.
static func build_topology(ring_count: int = DEFAULT_RING_COUNT, radius_start: float = DEFAULT_RADIUS_START,
		gap: float = DEFAULT_GAP, elevation: float = DEFAULT_ELEVATION) -> Array:
	ring_count = maxi(1, ring_count)
	radius_start = maxf(0.1, radius_start)
	gap = maxf(0.1, gap)
	var rings: Array = []
	for i in ring_count:
		var ring_index := i + 1
		rings.append({
			"ring": ring_index,
			"radius": radius_start + gap * float(i),
			"elevation": elevation,
			"adjacent_in": ring_index - 1 if ring_index > 1 else -1,
			"adjacent_out": ring_index + 1 if ring_index < ring_count else -1,
		})
	return rings


## Chunk every ring in `ring_topology` into `segment_arc_deg`-wide arc-segment wedges. Returns one
## Dictionary per (ring, arc) wedge:
##   {"ring": int, "arc": int, "angle_start_deg": float, "angle_end_deg": float, "radius": float,
##    "elevation": float, "hallway_width": float}
## `arc` indices match ChunkLifecycleManager.ring_key_fn's own indexing (0..segments_per_ring-1, 0
## at angle 0, increasing with angle) so a chunk key from that manager maps 1:1 to a wedge here.
## `hallway_width` carries `gap` per-chunk so `build_wedge_mesh` needs nothing beyond the chunk
## dict itself (a wedge is fully self-describing).
static func wedge_chunks(ring_topology: Array, segment_arc_deg: float = DEFAULT_SEGMENT_ARC_DEG,
		gap: float = DEFAULT_GAP) -> Array:
	segment_arc_deg = clampf(segment_arc_deg, 1.0, 180.0)
	gap = maxf(0.1, gap)
	var segments_per_ring: int = maxi(1, int(round(360.0 / segment_arc_deg)))
	var step := 360.0 / float(segments_per_ring)
	var chunks: Array = []
	for ring_data in ring_topology:
		for arc in segments_per_ring:
			chunks.append({
				"ring": ring_data["ring"],
				"arc": arc,
				"angle_start_deg": step * float(arc),
				"angle_end_deg": step * float(arc + 1),
				"radius": ring_data["radius"],
				"elevation": ring_data["elevation"],
				"hallway_width": gap,
			})
	return chunks


## Shared shell cross-section extents (outer/inner half-width/half-height) from the three tunables
## every cross-section computation (mesh building AND `wall_surface_uv`'s placement math) derives
## from — factored out so the two stay in agreement by construction rather than by copy-paste.
static func _shell_extents(hallway_width: float, wall_thickness: float, ellipse_ratio: float) -> Dictionary:
	wall_thickness = maxf(0.01, wall_thickness)
	ellipse_ratio = maxf(0.05, ellipse_ratio)
	var hw_outer := hallway_width * 0.5
	var hh_outer := hw_outer * ellipse_ratio
	var hw_inner: float = maxf(0.01, hw_outer - wall_thickness)
	var hh_inner: float = maxf(0.01, hh_outer - wall_thickness)
	return {"hw_outer": hw_outer, "hh_outer": hh_outer, "hw_inner": hw_inner, "hh_inner": hh_inner}


## Build the extruded hollow elliptical-shell hallway MESH for one wedge chunk (as returned by
## `wedge_chunks()`): an elliptical ring cross-section (radial half-width = hallway_width/2,
## vertical half-height = that half-width * `ellipse_ratio`) swept along the wedge's angular span
## at `chunk.radius`, with a `wall_thickness`-thick shell (outer + inner elliptical walls) so the
## corridor interior is genuinely hollow/walkable, plus flat end caps closing the wedge's two open
## angular ends (so each wedge is a self-contained closed solid, instanceable/cullable on its own).
## Centered on the world origin, at world Y = chunk.elevation.
##
## `dome_apex_height` (increment 2, DQ-e9516770b): when >= 0.0, the UPPER half of the cross-section
## (`sin(theta) > 0` — the ceiling; the floor half is always left untouched, per Q2) blends toward a
## single point at world Y = `chunk.elevation + dome_apex_height` as it approaches the crown — BOTH
## shell walls converge to that SAME point, exactly Liam's "two shells... converge at a point near
## the roof." At the default sentinel (< 0.0) this is a no-op: identical output to increment 1.
##
## Every vertex also now carries a real UV: `u` = world-unit arc length around the FULL ring (not
## wedge-relative, so adjacent wedges tile seamlessly), `v` = normalized [0,1) cross-section angle —
## the SAME (u, v) convention `wall_surface_uv()` below uses for its placement domain, so a texture
## and the cavity-carver's future placement domain agree on what "position on the wall" means.
static func build_wedge_mesh(chunk: Dictionary, wall_thickness: float = DEFAULT_WALL_THICKNESS,
		ellipse_ratio: float = DEFAULT_ELLIPSE_RATIO, cross_segments: int = 8, arc_steps: int = 2,
		dome_apex_height: float = DEFAULT_DOME_APEX_HEIGHT) -> Mesh:
	cross_segments = maxi(3, cross_segments)
	arc_steps = maxi(1, arc_steps)

	var radius: float = float(chunk.get("radius", DEFAULT_RADIUS_START))
	var elevation: float = float(chunk.get("elevation", DEFAULT_ELEVATION))
	var hallway_width: float = float(chunk.get("hallway_width", DEFAULT_GAP))
	var a0 := deg_to_rad(float(chunk.get("angle_start_deg", 0.0)))
	var a1 := deg_to_rad(float(chunk.get("angle_end_deg", DEFAULT_SEGMENT_ARC_DEG)))

	var extents := _shell_extents(hallway_width, wall_thickness, ellipse_ratio)
	var hw_outer: float = extents["hw_outer"]
	var hh_outer: float = extents["hh_outer"]
	var hw_inner: float = extents["hw_inner"]
	var hh_inner: float = extents["hh_inner"]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# (arc, cross) grid of outer + inner ellipse points (+ matching UVs), so the two shell surfaces
	# (and the two end caps) all share exactly the same vertex layout.
	var outer: Array = []  # outer[i][j] = Vector3, i in 0..arc_steps, j in 0..cross_segments
	var inner: Array = []
	var outer_uv: Array = []
	var inner_uv: Array = []
	for i in (arc_steps + 1):
		var a := lerpf(a0, a1, float(i) / float(arc_steps))
		var radial := Vector3(cos(a), 0.0, sin(a))
		var up := Vector3(0.0, 1.0, 0.0)
		var center := Vector3(cos(a) * radius, elevation, sin(a) * radius)
		var u := radius * a  # ring-global arc length — continuous across wedge boundaries
		var orow: Array = []
		var irow: Array = []
		var ouv_row: Array = []
		var iuv_row: Array = []
		for j in (cross_segments + 1):
			var theta := TAU * float(j) / float(cross_segments)
			var ocx := cos(theta) * hw_outer
			var ocy := sin(theta) * hh_outer
			var icx := cos(theta) * hw_inner
			var icy := sin(theta) * hh_inner
			if dome_apex_height >= 0.0:
				# Roof-convergence blend: weight 0 at the springlines (theta=0/PI), 1 at the crown
				# (theta=PI/2). sin(theta) is already <= 0 for the whole floor half (PI..TAU), so
				# clamping to >= 0 leaves the floor completely untouched with no explicit branch.
				var s := clampf(sin(theta), 0.0, 1.0)
				ocx = lerpf(ocx, 0.0, s)
				ocy = lerpf(ocy, dome_apex_height, s)
				icx = lerpf(icx, 0.0, s)
				icy = lerpf(icy, dome_apex_height, s)
			orow.append(center + radial * ocx + up * ocy)
			irow.append(center + radial * icx + up * icy)
			var uv := Vector2(u, theta / TAU)
			ouv_row.append(uv)
			iuv_row.append(uv)
		outer.append(orow)
		inner.append(irow)
		outer_uv.append(ouv_row)
		inner_uv.append(iuv_row)

	for i in arc_steps:
		for j in cross_segments:
			# Outer shell wall: faces OUTWARD (away from the corridor interior).
			_quad(st, outer[i][j], outer[i + 1][j], outer[i + 1][j + 1], outer[i][j + 1],
				outer_uv[i][j], outer_uv[i + 1][j], outer_uv[i + 1][j + 1], outer_uv[i][j + 1])
			# Inner shell wall: faces INWARD (toward the corridor interior) — reversed winding vs.
			# the outer wall so both normals point away from the shell's own solid material.
			_quad(st, inner[i][j + 1], inner[i + 1][j + 1], inner[i + 1][j], inner[i][j],
				inner_uv[i][j + 1], inner_uv[i + 1][j + 1], inner_uv[i + 1][j], inner_uv[i][j])

	# End caps at the wedge's two open angular ends (i=0 and i=arc_steps): an annular-ellipse ring
	# connecting outer to inner, closing the shell into a solid wedge segment.
	for j in cross_segments:
		_quad(st, inner[0][j], inner[0][j + 1], outer[0][j + 1], outer[0][j],
			inner_uv[0][j], inner_uv[0][j + 1], outer_uv[0][j + 1], outer_uv[0][j])
		_quad(st, outer[arc_steps][j], outer[arc_steps][j + 1], inner[arc_steps][j + 1], inner[arc_steps][j],
			outer_uv[arc_steps][j], outer_uv[arc_steps][j + 1], inner_uv[arc_steps][j + 1], inner_uv[arc_steps][j])

	st.generate_normals()
	return st.commit()


## The unrolled-cylinder UV-strip DOMAIN for one ring's INNER shell surface (the corridor-interior-
## facing wall — what a person walking the hallway sees, and where §2.2's alcoves/niches get carved
## FROM). Shaped to plug directly into `ScatterComposer.sample()`'s own contract
## (renderers/scatter_composer.gd): `domain_min`/`domain_max` are the 2D sampling rectangle,
## `to_transform` maps an accepted (u, v) domain point straight to a placement `Transform3D` on the
## wall — the Wave 3 cavity carver's entire "unroll to 2D, run Poisson-disk, map back onto the
## cylinder" (plan §2.2) reduces to calling `ScatterComposer.sample(domain_min, domain_max, min_dist,
## field_fn, seed, call_target, to_transform)` with THIS dict's fields, unchanged.
##
##   u (domain.x) — world-unit arc length around the FULL ring, [0, 2*PI*radius).
##   v (domain.y) — normalized [0, 1) cross-section angle around the inner ellipse (0/1 = springline,
##                   0.5 = crown/ceiling-top) — the SAME (u, v) convention `build_wedge_mesh`'s own
##                   UVs use, so a texture and this placement domain agree on "position on the wall".
##
## The returned `to_transform`'s Transform3D basis: origin = the wall-surface point; -Z (forward)
## points INTO the shell material (the carve direction, away from the corridor interior — subtracting
## an SDF shape along +Z from that origin, per plan §2.5, carves a niche visible from inside the
## hallway); the up axis stays close to world-up (falls back to the ring's own radial direction only
## at the near-vertical crown/nadir, where world-up is degenerate) so eye/almond-shaped carves orient
## upright by default.
static func wall_surface_uv(ring_data: Dictionary, wall_thickness: float = DEFAULT_WALL_THICKNESS,
		ellipse_ratio: float = DEFAULT_ELLIPSE_RATIO, hallway_width: float = DEFAULT_GAP) -> Dictionary:
	var radius: float = maxf(0.0001, float(ring_data.get("radius", DEFAULT_RADIUS_START)))
	var elevation: float = float(ring_data.get("elevation", DEFAULT_ELEVATION))
	var extents := _shell_extents(hallway_width, wall_thickness, ellipse_ratio)
	var hw_inner: float = extents["hw_inner"]
	var hh_inner: float = extents["hh_inner"]

	var to_transform := func(p: Vector2, _rng: RandomNumberGenerator) -> Transform3D:
		var a := p.x / radius
		var theta := clampf(p.y, 0.0, 1.0) * TAU
		var radial := Vector3(cos(a), 0.0, sin(a))
		var up := Vector3(0.0, 1.0, 0.0)
		var center := Vector3(cos(a) * radius, elevation, sin(a) * radius)
		var point := center + radial * (cos(theta) * hw_inner) + up * (sin(theta) * hh_inner)
		# Outward ellipse-normal (points from the inner surface INTO the shell material) in the
		# local (radial, up) 2D basis, then lifted to 3D.
		var n2 := Vector2(cos(theta) / maxf(hw_inner, 0.0001), sin(theta) / maxf(hh_inner, 0.0001))
		if n2.length() < 0.0001:
			n2 = Vector2(1.0, 0.0)
		n2 = n2.normalized()
		var normal := (radial * n2.x + up * n2.y).normalized()
		var up_hint := Vector3.UP
		if absf(normal.dot(up_hint)) > 0.99:
			up_hint = radial
		var basis := Basis.looking_at(normal, up_hint)
		return Transform3D(basis, point)

	return {
		"ring": int(ring_data.get("ring", 0)),
		"domain_min": Vector2(0.0, 0.0),
		"domain_max": Vector2(TAU * radius, 1.0),
		"to_transform": to_transform,
	}


## World-space centroid of a wedge chunk (midpoint of its angular span, at its ring's radius/
## elevation) — the position a caller measures camera distance against, both for LOD-tier decisions
## (`wedge_lod_tier` below) and general chunk-streaming distance checks.
static func wedge_world_center(chunk: Dictionary) -> Vector3:
	var radius: float = float(chunk.get("radius", DEFAULT_RADIUS_START))
	var elevation: float = float(chunk.get("elevation", DEFAULT_ELEVATION))
	var a0: float = float(chunk.get("angle_start_deg", 0.0))
	var a1: float = float(chunk.get("angle_end_deg", DEFAULT_SEGMENT_ARC_DEG))
	var mid := deg_to_rad((a0 + a1) * 0.5)
	return Vector3(cos(mid) * radius, elevation, sin(mid) * radius)


## Decide (and commit, via `tracker`) ONE wedge's LOD tier for the current frame — node 1's spec
## names `detail_field` as an input port ("LOD budget in"); this is that wiring. Per this file's own
## increment-1 design note (top of file), `RingScaffoldGenerator` never decides LOD tier on its own —
## this is CALLER-SIDE glue a scene driver calls once per visible wedge per frame, composing
## `DetailField.DetailLODTracker` (renderers/detail_field.gd, Wave 1 item 1.2) with
## `wedge_world_center()` above. `item_id` uses the SAME `"%d_%d" % [ring, arc]` key convention
## `build()`'s `meshes` dict already uses, so a caller can key both by the identical string.
## `detail` — the [0..1] budget read from a `DetailField.build()` field at the wedge's position (or
## pass 1.0 for plain distance-only LOD, `DetailField`'s own documented no-field fallback). Returns
## `DetailLODTracker.update()`'s own shape: `{"tier", "swapped", "previous_tier"}`.
static func wedge_lod_tier(chunk: Dictionary, camera_pos: Vector3, tracker: DetailField.DetailLODTracker,
		detail: float, near_distance: float, hysteresis: float = 0.15) -> Dictionary:
	var item_id := "%d_%d" % [int(chunk.get("ring", 0)), int(chunk.get("arc", 0))]
	var distance := camera_pos.distance_to(wedge_world_center(chunk))
	return tracker.update(item_id, distance, detail, near_distance, hysteresis)


## Export every wedge chunk MESH in `meshes` (as returned by `build()`'s own `meshes` dict) to its
## own GLB file under `out_dir` — node 1's "hallway_shell_mesh (chunked GLB, one per arc-segment)"
## output shape (increment 1 returned in-memory `Mesh` resources only). Reuses
## `GltfExporter.export_mesh_to_file()` (renderers/gltf_exporter.gd, SPEC-754's chosen export
## mechanism). Returns `{key(String) -> Error(int)}`; `OK` (0) means that chunk's `.glb` wrote
## successfully. `out_dir` is created if missing.
static func export_wedge_chunks_glb(meshes: Dictionary, out_dir: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var base := out_dir.rstrip("/")
	var results: Dictionary = {}
	for key in meshes.keys():
		var mesh: Mesh = meshes[key]
		var out_path := "%s/wedge_%s.glb" % [base, String(key)]
		results[key] = GltfExporter.export_mesh_to_file(mesh, out_path, "Wedge_%s" % String(key))
	return results


## Top-level convenience: build the full ring-scaffold output for a scene from raw tunables in ONE
## call — the shape a caller (or a future node-graph `RingScaffoldGenerator` node wrapper) consumes.
## Returns:
##   {"ring_topology": Array, "chunks": Array, "meshes": Dictionary, "wall_surface_uv": Dictionary}
## `meshes` is keyed `"%d_%d" % [ring, arc]` -> Mesh, one per chunk (matching node 1's
## "hallway_shell_mesh (chunked GLB, one per arc-segment)" output shape; use
## `export_wedge_chunks_glb(result["meshes"], out_dir)` to actually write the per-chunk GLBs).
## `wall_surface_uv` (increment 2) is keyed by ring index (int) -> that ring's `wall_surface_uv()`
## domain descriptor. `tunables` accepts `dome_apex_height` (increment 2; omit/negative = the plain-
## ellipse increment-1 roof, unchanged default).
static func build(tunables: Dictionary = {}) -> Dictionary:
	var ring_count: int = int(tunables.get("ring_count", DEFAULT_RING_COUNT))
	var radius_start: float = float(tunables.get("radius_start", DEFAULT_RADIUS_START))
	var gap: float = float(tunables.get("gap", DEFAULT_GAP))
	var elevation: float = float(tunables.get("elevation", DEFAULT_ELEVATION))
	var segment_arc_deg: float = float(tunables.get("segment_arc_deg", DEFAULT_SEGMENT_ARC_DEG))
	var wall_thickness: float = float(tunables.get("wall_thickness", DEFAULT_WALL_THICKNESS))
	var ellipse_ratio: float = float(tunables.get("ellipse_ratio", DEFAULT_ELLIPSE_RATIO))
	var dome_apex_height: float = float(tunables.get("dome_apex_height", DEFAULT_DOME_APEX_HEIGHT))

	var topo := build_topology(ring_count, radius_start, gap, elevation)
	var chunks := wedge_chunks(topo, segment_arc_deg, gap)
	var meshes: Dictionary = {}
	for chunk in chunks:
		var key := "%d_%d" % [int(chunk["ring"]), int(chunk["arc"])]
		meshes[key] = build_wedge_mesh(chunk, wall_thickness, ellipse_ratio, 8, 2, dome_apex_height)
	var wall_uv: Dictionary = {}
	for ring_data in topo:
		wall_uv[int(ring_data["ring"])] = wall_surface_uv(ring_data, wall_thickness, ellipse_ratio, gap)
	return {"ring_topology": topo, "chunks": chunks, "meshes": meshes, "wall_surface_uv": wall_uv}


## A CCW-wound quad (a,b,c,d) as two triangles, with per-vertex UVs (increment 2 — defaults to
## Vector2.ZERO for any future caller that doesn't need texture coordinates); normals computed by
## SurfaceTool.generate_normals() (called once over the whole mesh in build_wedge_mesh — cheaper than
## per-face normals here, and correctly smooths across the cross-section grid, matching the "real
## instanced geometry" quality bar the LOD-near tier should look like).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uva: Vector2 = Vector2.ZERO, uvb: Vector2 = Vector2.ZERO,
		uvc: Vector2 = Vector2.ZERO, uvd: Vector2 = Vector2.ZERO) -> void:
	st.set_uv(uva); st.add_vertex(a)
	st.set_uv(uvb); st.add_vertex(b)
	st.set_uv(uvc); st.add_vertex(c)
	st.set_uv(uva); st.add_vertex(a)
	st.set_uv(uvc); st.add_vertex(c)
	st.set_uv(uvd); st.add_vertex(d)
