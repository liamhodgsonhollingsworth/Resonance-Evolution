class_name BridgeGenerator
extends RefCounted
## BridgeGenerator -- node 9 ("Cavity / bridge tier") of
## notes/planning/underground_halls_plan_2026_07_14.md, Wave 5 item 5.1 (B) of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-225b57d9). NEW, 8h: "parametric-part
## path assembly, a rect-cross-section SIBLING of pipe.py's path mode" -- i.e. the SAME "loft a
## cross-section along a path between two endpoints" shape `proc3d/parts/pipe.py`'s path mode already
## uses for railings, reimplemented directly in GDScript with a RECTANGULAR cross-section instead of a
## round one (this module never calls into the Python proc3d tools -- those run offline/export-side;
## this is a live per-scene generator, same house style as `NonOverlappingCavityCarver`'s own
## SurfaceTool loft helpers, which it reuses the TECHNIQUE from, not the code).
##
## "Connects pairs of cavities of similar elevation/offset with a rectangular-cross-section span whose
## LAYOUT (not cross-section) is an angled ramp (up/down, roughly triangular in side profile)."
##
## CANDIDATE-PAIR INTERPRETATION (a documented decision, the plan's own text does not fully pin this
## down -- see the plan's own "restriction on how close in angle" phrasing): rings are concentric,
## sharing one world center, so every cavity has a well-defined WORLD ANGLE (atan2 of its origin's x/z)
## independent of which ring carved it. A bridge is a catwalk spanning the OPEN ANNULAR GAP BETWEEN
## TWO DIFFERENT RINGS (same-ring cavities are already reachable by walking that ring's own corridor;
## same-wall cavities already linked by `NonOverlappingCavityCarver`'s own connect_adjacent through-
## passages are a DIFFERENT connection already built -- skipped here via `pair_id` to avoid a redundant
## double-bridge over the exact same wall opening). `max_angle_delta` restricts candidate pairs to
## cavities at a SIMILAR WORLD ANGLE on their two different rings (a bridge crossing straight across the
## gap, not a long diagonal one) -- exactly Liam's "restriction on how close in angle" callout.
## `max_elevation_delta` caps how much floor-height difference a single span may cross (keeps the ramp
## from becoming absurdly steep). `connect_probability` is the density-tuning Bernoulli draw over every
## surviving candidate pair (deterministic per `seed`).
##
## Deck geometry: a solid rectangular-cross-section prism, its LONG axis following the straight line
## between the two cavities' own transform origins (offset slightly along each cavity's own +Z --
## "into the corridor interior" per `wall_surface_uv`'s convention -- so the deck starts/ends just
## inside each opening, not flush against the rock). When the two cavities sit at different elevations
## this straight span IS the "angled ramp... roughly triangular in side profile" the plan describes --
## no separate ramp geometry needed, the deck's own tilt reads as the ramp. `ramp_style` is a plan-named
## enum tunable; only `"simple"` (a single straight span) is implemented per the plan's own "simple for
## now" -- any other value falls back to `"simple"`, documented, not a silent failure.
##
## Every returned entry: {"ring_a": int, "ring_b": int, "mesh": Mesh (world-space vertices, same
## "return ready components" convention cavity_carver.gd's own meshes use -- place with an IDENTITY
## transform), "length": float, "elevation_delta": float, "angle_delta": float, "pa": Vector3,
## "pb": Vector3, "right": Vector3, "up": Vector3, "deck_width": float, "deck_thickness": float}.
## The last 6 fields are an ADDITIVE increment (2026-07-15, DISPATCH claim
## underground-railing-iteration-2026-07-15) -- same "increment, existing fields/behavior
## unchanged" convention `ring_scaffold.gd`'s own "INCREMENT 2" section documents. They expose the
## deck's own endpoint/frame data (previously computed only inside the private `_deck_mesh` box
## builder) so the new `RailingGenerator` (`renderers/railing_generator.gd`) can derive the deck's
## two top-edge poly-lines and build a real railing along them, instead of re-deriving this
## geometry itself. `pa`/`pb` are the SAME inset endpoints `_deck_mesh` builds its box between;
## `right`/`up` are that box's own cross-section axes; `deck_width`/`deck_thickness` are the
## resolved tunables used to build it -- a caller offsets `right * deck_width * 0.5` from the
## `pa`-`pb` centerline (at `up * deck_thickness * 0.5`, the deck's TOP surface) to get either edge.
##
## Tunables (the EXACT four named by the plan -- no more, per no-auto-generalization):
##   max_angle_delta       (float, radians) -- max world-angle difference between two rings' cavities.
##   max_elevation_delta   (float) -- max floor-height difference a span may cross.
##   connect_probability   (float 0..1) -- density-tuning Bernoulli draw over surviving candidates.
##   ramp_style            (String enum) -- only "simple" implemented; anything else falls back to it.
## (Implementation-detail defaults below -- `deck_width`/`deck_thickness`/`seed` -- documented,
## overridable via `tunables`, same pattern every sibling module in this arc uses.)

const DEFAULT_MAX_ANGLE_DELTA := 0.35        # radians (~20 deg)
const DEFAULT_MAX_ELEVATION_DELTA := 6.0     # world units
const DEFAULT_CONNECT_PROBABILITY := 0.5
const RAMP_STYLE_SIMPLE := "simple"
const DEFAULT_RAMP_STYLE := RAMP_STYLE_SIMPLE
const DEFAULT_SEED := 0
const DEFAULT_DECK_WIDTH := 1.2              # world units, rectangular cross-section
const DEFAULT_DECK_THICKNESS := 0.18
const DEFAULT_ENDPOINT_INSET := 0.15         # how far each end sits proud of its wall surface


## Generate bridge decks across `cavity_instances` (NonOverlappingCavityCarver.carve()'s own output).
## Returns an Array[Dictionary] of `bridge_meshes` (see file header for the exact shape).
static func generate(cavity_instances: Array, tunables: Dictionary = {}) -> Array[Dictionary]:
	var max_angle_delta: float = maxf(0.0, float(tunables.get("max_angle_delta", DEFAULT_MAX_ANGLE_DELTA)))
	var max_elevation_delta: float = maxf(0.0, float(tunables.get("max_elevation_delta", DEFAULT_MAX_ELEVATION_DELTA)))
	var connect_probability: float = clampf(float(tunables.get("connect_probability", DEFAULT_CONNECT_PROBABILITY)), 0.0, 1.0)
	var ramp_style: String = String(tunables.get("ramp_style", DEFAULT_RAMP_STYLE))
	if ramp_style != RAMP_STYLE_SIMPLE:
		ramp_style = RAMP_STYLE_SIMPLE
	var seed_value: int = int(tunables.get("seed", DEFAULT_SEED))
	var deck_width: float = maxf(0.05, float(tunables.get("deck_width", DEFAULT_DECK_WIDTH)))
	var deck_thickness: float = maxf(0.02, float(tunables.get("deck_thickness", DEFAULT_DECK_THICKNESS)))
	var inset: float = float(tunables.get("endpoint_inset", DEFAULT_ENDPOINT_INSET))

	var out: Array[Dictionary] = []
	if connect_probability <= 0.0 or cavity_instances.is_empty():
		return out

	var anchors := _anchors(cavity_instances)
	var pair_index := 0
	for i in anchors.size():
		for j in range(i + 1, anchors.size()):
			var a: Dictionary = anchors[i]
			var b: Dictionary = anchors[j]
			if int(a["ring"]) == int(b["ring"]):
				continue  # same-ring cavities are already reachable by walking that ring's own corridor
			var pair_id_a := String(a.get("pair_id", ""))
			if pair_id_a != "" and pair_id_a == String(b.get("pair_id", "")):
				continue  # already linked by cavity_carver's own connect_adjacent through-passage
			var angle_delta := _angle_delta(float(a["angle"]), float(b["angle"]))
			if angle_delta > max_angle_delta:
				continue
			var elevation_delta := absf(float(a["elevation"]) - float(b["elevation"]))
			if elevation_delta > max_elevation_delta:
				continue
			var roll_seed := int(hash(Vector3i(seed_value, int(a["index"]), int(b["index"]))))
			var rng := RandomNumberGenerator.new()
			rng.seed = roll_seed
			pair_index += 1
			if rng.randf() >= connect_probability:
				continue
			var frame := _deck_frame(a["transform"], b["transform"], inset)
			if frame.is_empty():
				continue
			var mesh := _deck_mesh_from_frame(frame, deck_width, deck_thickness)
			out.append({
				"ring_a": int(a["ring"]), "ring_b": int(b["ring"]), "mesh": mesh,
				"length": (a["origin"] as Vector3).distance_to(b["origin"]),
				"elevation_delta": elevation_delta, "angle_delta": angle_delta,
				"pa": frame["pa"], "pb": frame["pb"], "right": frame["right"], "up": frame["up"],
				"deck_width": deck_width, "deck_thickness": deck_thickness,
			})
	return out


## Per-cavity anchor data: world angle (atan2 around the shared world center -- valid regardless of
## which ring carved the cavity, since every ring is centered on world origin), elevation, origin,
## the cavity's own transform (endpoint pose), ring index, pair_id (for through-passage exclusion),
## and a stable running index (the roll-seed join key -- same lesson cavity_carver.gd's own docstring
## records about ScatterComposer.Placement.seed NOT being a unique per-point id).
static func _anchors(cavity_instances: Array) -> Array:
	var out: Array = []
	var idx := 0
	for inst in cavity_instances:
		var d: Dictionary = inst
		if not d.has("transform"):
			continue
		var t: Transform3D = d["transform"]
		out.append({
			"index": idx, "ring": int(d.get("ring", 0)), "elevation": float(d.get("elevation", 0.0)),
			"origin": t.origin, "angle": atan2(t.origin.z, t.origin.x), "transform": t,
			"pair_id": String(d.get("pair_id", "")),
		})
		idx += 1
	return out

## Smallest angular distance between two angles (radians), wrapped into [0, PI].
static func _angle_delta(a: float, b: float) -> float:
	var d := fmod(absf(a - b), TAU)
	return mini(d, TAU - d)


## Endpoint + cross-section FRAME for a deck spanning from `xform_a`'s origin to `xform_b`'s origin,
## each end inset `inset` world units along that cavity's own +Z (into the corridor interior, per
## wall_surface_uv's convention -- matches cavity_carver's own "sit proud, visible from the hallway"
## endpoint treatment). The frame is oriented by the span direction itself and a world-up-derived
## "deck up" axis (falls back to the span direction's own perpendicular when the span is
## near-vertical). Returns `{}` (empty) when the span is degenerate (near-zero length); otherwise
## `{"pa": Vector3, "pb": Vector3, "dir": Vector3, "right": Vector3, "up": Vector3, "length": float}`.
## Factored out (2026-07-15, additive) so `RailingGenerator` can derive the deck's own top-edge
## poly-lines from the SAME frame `_deck_mesh_from_frame` below builds its box from -- see the
## `generate()` return-shape docstring above.
static func _deck_frame(xform_a: Transform3D, xform_b: Transform3D, inset: float) -> Dictionary:
	var pa: Vector3 = xform_a.origin + xform_a.basis.z * inset
	var pb: Vector3 = xform_b.origin + xform_b.basis.z * inset
	var dir := pb - pa
	var length := dir.length()
	if length < 0.001:
		return {}
	dir /= length
	var up_hint := Vector3.UP
	if absf(dir.dot(up_hint)) > 0.98:
		up_hint = xform_a.basis.y
	var right := dir.cross(up_hint).normalized()
	if right.length() < 0.001:
		right = Vector3.RIGHT
	var up := right.cross(dir).normalized()
	return {"pa": pa, "pb": pb, "dir": dir, "right": right, "up": up, "length": length}


## A solid rectangular-cross-section prism built from a `_deck_frame()` result -- a FLAT deck
## (walkable top surface), not a round pipe. Pure geometry, no re-derivation of the frame (kept in
## exact agreement with whatever frame `generate()` attached to its output entry).
static func _deck_mesh_from_frame(frame: Dictionary, width: float, thickness: float) -> Mesh:
	var pa: Vector3 = frame["pa"]
	var pb: Vector3 = frame["pb"]
	var right: Vector3 = frame["right"]
	var up: Vector3 = frame["up"]

	var hw := width * 0.5
	var ht := thickness * 0.5
	# 8 corners of a rectangular prism from pa to pb.
	var corners_a := [
		pa + right * hw + up * ht, pa - right * hw + up * ht,
		pa - right * hw - up * ht, pa + right * hw - up * ht,
	]
	var corners_b := [
		pb + right * hw + up * ht, pb - right * hw + up * ht,
		pb - right * hw - up * ht, pb + right * hw - up * ht,
	]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 4 side faces (loft) + 2 end caps -- a fully closed solid, same "solid, not floating plane"
	# discipline DirtFloorInfill's wedge uses.
	for i in 4:
		var j := (i + 1) % 4
		_quad(st, corners_a[i], corners_a[j], corners_b[j], corners_b[i])
	_quad(st, corners_a[3], corners_a[2], corners_a[1], corners_a[0])
	_quad(st, corners_b[0], corners_b[1], corners_b[2], corners_b[3])
	st.generate_normals()
	return st.commit()

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)
