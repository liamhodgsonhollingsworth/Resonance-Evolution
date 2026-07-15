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


## Build the extruded hollow elliptical-shell hallway MESH for one wedge chunk (as returned by
## `wedge_chunks()`): an elliptical ring cross-section (radial half-width = hallway_width/2,
## vertical half-height = that half-width * `ellipse_ratio`) swept along the wedge's angular span
## at `chunk.radius`, with a `wall_thickness`-thick shell (outer + inner elliptical walls) so the
## corridor interior is genuinely hollow/walkable, plus flat end caps closing the wedge's two open
## angular ends (so each wedge is a self-contained closed solid, instanceable/cullable on its own).
## Centered on the world origin, at world Y = chunk.elevation.
static func build_wedge_mesh(chunk: Dictionary, wall_thickness: float = DEFAULT_WALL_THICKNESS,
		ellipse_ratio: float = DEFAULT_ELLIPSE_RATIO, cross_segments: int = 8, arc_steps: int = 2) -> Mesh:
	wall_thickness = maxf(0.01, wall_thickness)
	ellipse_ratio = maxf(0.05, ellipse_ratio)
	cross_segments = maxi(3, cross_segments)
	arc_steps = maxi(1, arc_steps)

	var radius: float = float(chunk.get("radius", DEFAULT_RADIUS_START))
	var elevation: float = float(chunk.get("elevation", DEFAULT_ELEVATION))
	var hallway_width: float = float(chunk.get("hallway_width", DEFAULT_GAP))
	var a0 := deg_to_rad(float(chunk.get("angle_start_deg", 0.0)))
	var a1 := deg_to_rad(float(chunk.get("angle_end_deg", DEFAULT_SEGMENT_ARC_DEG)))

	var hw_outer := hallway_width * 0.5
	var hh_outer := hw_outer * ellipse_ratio
	var hw_inner: float = maxf(0.01, hw_outer - wall_thickness)
	var hh_inner: float = maxf(0.01, hh_outer - wall_thickness)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# (arc, cross) grid of outer + inner ellipse points, so the two shell surfaces (and the two end
	# caps) all share exactly the same vertex layout.
	var outer: Array = []  # outer[i][j] = Vector3, i in 0..arc_steps, j in 0..cross_segments
	var inner: Array = []
	for i in (arc_steps + 1):
		var a := lerpf(a0, a1, float(i) / float(arc_steps))
		var radial := Vector3(cos(a), 0.0, sin(a))
		var up := Vector3(0.0, 1.0, 0.0)
		var center := Vector3(cos(a) * radius, elevation, sin(a) * radius)
		var orow: Array = []
		var irow: Array = []
		for j in (cross_segments + 1):
			var theta := TAU * float(j) / float(cross_segments)
			orow.append(center + radial * (cos(theta) * hw_outer) + up * (sin(theta) * hh_outer))
			irow.append(center + radial * (cos(theta) * hw_inner) + up * (sin(theta) * hh_inner))
		outer.append(orow)
		inner.append(irow)

	for i in arc_steps:
		for j in cross_segments:
			# Outer shell wall: faces OUTWARD (away from the corridor interior).
			_quad(st, outer[i][j], outer[i + 1][j], outer[i + 1][j + 1], outer[i][j + 1])
			# Inner shell wall: faces INWARD (toward the corridor interior) — reversed winding vs.
			# the outer wall so both normals point away from the shell's own solid material.
			_quad(st, inner[i][j + 1], inner[i + 1][j + 1], inner[i + 1][j], inner[i][j])

	# End caps at the wedge's two open angular ends (i=0 and i=arc_steps): an annular-ellipse ring
	# connecting outer to inner, closing the shell into a solid wedge segment.
	for j in cross_segments:
		_quad(st, inner[0][j], inner[0][j + 1], outer[0][j + 1], outer[0][j])
		_quad(st, outer[arc_steps][j], outer[arc_steps][j + 1], inner[arc_steps][j + 1], inner[arc_steps][j])

	st.generate_normals()
	return st.commit()


## Top-level convenience: build the full increment-1 output for a ring scaffold from raw tunables
## in ONE call — the shape a caller (or a future node-graph `RingScaffoldGenerator` node wrapper)
## consumes. Returns:
##   {"ring_topology": Array, "chunks": Array, "meshes": Dictionary}
## `meshes` is keyed `"%d_%d" % [ring, arc]` -> Mesh, one per chunk (matching node 1's
## "hallway_shell_mesh (chunked GLB, one per arc-segment)" output shape — the GLB-export step
## itself is a build-time concern, not this increment's).
static func build(tunables: Dictionary = {}) -> Dictionary:
	var ring_count: int = int(tunables.get("ring_count", DEFAULT_RING_COUNT))
	var radius_start: float = float(tunables.get("radius_start", DEFAULT_RADIUS_START))
	var gap: float = float(tunables.get("gap", DEFAULT_GAP))
	var elevation: float = float(tunables.get("elevation", DEFAULT_ELEVATION))
	var segment_arc_deg: float = float(tunables.get("segment_arc_deg", DEFAULT_SEGMENT_ARC_DEG))
	var wall_thickness: float = float(tunables.get("wall_thickness", DEFAULT_WALL_THICKNESS))
	var ellipse_ratio: float = float(tunables.get("ellipse_ratio", DEFAULT_ELLIPSE_RATIO))

	var topo := build_topology(ring_count, radius_start, gap, elevation)
	var chunks := wedge_chunks(topo, segment_arc_deg, gap)
	var meshes: Dictionary = {}
	for chunk in chunks:
		var key := "%d_%d" % [int(chunk["ring"]), int(chunk["arc"])]
		meshes[key] = build_wedge_mesh(chunk, wall_thickness, ellipse_ratio)
	return {"ring_topology": topo, "chunks": chunks, "meshes": meshes}


## A CCW-wound quad (a,b,c,d) as two triangles, normals computed by SurfaceTool.generate_normals()
## (called once over the whole mesh in build_wedge_mesh — cheaper than per-face normals here, and
## correctly smooths across the cross-section grid, matching the "real instanced geometry" quality
## bar the LOD-near tier should look like).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
