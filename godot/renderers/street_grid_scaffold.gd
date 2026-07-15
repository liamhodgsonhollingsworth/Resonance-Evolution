class_name StreetGridScaffold
extends RefCounted
## StreetGridScaffold -- node 1 ("Scaffolding tier") of
## notes/planning/brick_street_scene_plan_2026_07_14.md §4, Wave-A1 increment 1 of the brick-street
## scene (Project A). A Scaffold-node instance (method: recursive guillotine/BSP subdivision, plan
## §2.1) that packs a chunk into a random grid of rectangles ("lots") of varying tunable size, exactly
## Liam's spec (msg 1526645607974830253): "a particular generated street example on a procedurally
## generated random grid of rectangles of varying size from a particular range (tunable parameter),
## packed together."
##
## CHUNK-DETERMINISTIC by construction (plan §2.1's load-bearing property for "theoretically
## infinite, only generate around the player", msg 1526647718808649940): the RNG seed is derived
## ONLY from (world seed, packing seed, chunk_coord) via `hash()` -- no dependency on a neighboring
## chunk's solve, so any two callers building the SAME chunk_coord (this session, a re-visit, a
## different machine) get byte-identical output.
##
## CHUNK-BOUNDARY SEAM MITIGATION (plan §5 failure mode 1, "chunk-boundary packing seams (HIGH)"):
## every chunk's own OUTER BOUNDARY is a FORCED street margin (`street_width` wide, all four sides) --
## the BSP recursion only ever runs on the INTERIOR region inset from that margin. This is the plan's
## own chosen mitigation ("snap all chunk boundaries to a coarse fixed lattice... every chunk boundary
## is also a forced street line") -- adjacent chunks never need to agree about anything beyond "there
## is a street here", because there always is, by construction, on both sides of the seam.
##
## Pure DATA in -> pure DATA out (Rect2/Dictionary/Array only, world-space coordinates), no scene-tree
## dependency -- same portability invariant as the sibling renderers (RingScaffoldGenerator,
## ChunkLifecycleManager, DetailField, ScatterComposer).
##
## free_params (plan §4 node 1 shape, `{type,min,max,default}`):
##   lot_size_min  {type:float, min:4,   max:40, default:8}
##   lot_size_max  {type:float, min:6,   max:80, default:22}
##   street_width  {type:float, min:1.5, max:12, default:4}
##   packing_seed  {type:int,   min:0,   max:2^31, default:1}

const DEFAULT_CHUNK_SIZE := 64.0
const DEFAULT_LOT_SIZE_MIN := 8.0
const DEFAULT_LOT_SIZE_MAX := 22.0
const DEFAULT_STREET_WIDTH := 4.0
const DEFAULT_PACKING_SEED := 1

const MAX_SPLIT_DEPTH := 14         # recursion guard -- degenerate inputs stop, never hang/crash.
const STOP_PROBABILITY := 0.35      # once a region is within [lot_min, lot_max], this is the chance
                                     # each recursion step stops splitting further -- the "varying
                                     # size from a range" packing variety the spec asks for.
const ADJACENCY_MARGIN_FACTOR := 1.5  # lot_adjacency: two lots are "adjacent" if their footprints,
                                       # expanded by street_width * this factor, intersect.


## Build one chunk's street-grid scaffold. `chunk_coord` is the chunk's integer grid coordinate
## (matches ChunkLifecycleManager.grid_key_fn's own Vector2i XZ-grid convention, `cell_size ==
## chunk_size`, so a StreetChunkStreamer composing both agrees on what a "chunk" is). Returns:
##   {
##     "chunk_coord": Vector2i, "chunk_size": float, "origin": Vector2 (world XZ, chunk's min corner),
##     "building_footprints": Array of {"rect": Rect2, "id": int}   (world-space XZ rects, the lots),
##     "street_polygon": Array of Rect2                              (negative-space street strips --
##                        the perimeter margin ring + every internal split gutter; footprints +
##                        street_polygon together exactly tile the chunk's full Rect2),
##     "lot_adjacency": Dictionary lot_id:int -> Array[int]           (symmetric; ids of every OTHER
##                        lot whose footprint is within `street_width * 1.5` of this one),
##   }
static func build(seed: int, chunk_coord: Vector2i, chunk_size: float = DEFAULT_CHUNK_SIZE,
		lot_size_min: float = DEFAULT_LOT_SIZE_MIN, lot_size_max: float = DEFAULT_LOT_SIZE_MAX,
		street_width: float = DEFAULT_STREET_WIDTH, packing_seed: int = DEFAULT_PACKING_SEED) -> Dictionary:
	chunk_size = maxf(1.0, chunk_size)
	lot_size_min = maxf(0.5, lot_size_min)
	lot_size_max = maxf(lot_size_min, lot_size_max)
	street_width = clampf(street_width, 0.25, chunk_size * 0.4)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(seed), int(packing_seed), chunk_coord.x, chunk_coord.y])

	var origin := Vector2(float(chunk_coord.x), float(chunk_coord.y)) * chunk_size

	# The forced boundary-margin street (failure mode 1 mitigation) is a FULL `street_width`-wide
	# ring, inset `street_width` from each edge -- the SAME gutter width `_split()` uses between
	# sibling lots internally, so a chunk's own boundary reads as just another street, not a
	# differently-sized one. `_perimeter_strips` and this inset MUST agree (both use `street_width`,
	# not half of it) for the "footprints + street_polygon tile the chunk exactly" invariant to hold.
	var street_strips: Array = _perimeter_strips(origin, chunk_size, street_width)
	var interior := Rect2(origin + Vector2(street_width, street_width),
		Vector2(chunk_size - 2.0 * street_width, chunk_size - 2.0 * street_width))

	var footprints: Array = []
	_split(interior, lot_size_min, lot_size_max, street_width, rng, 0, footprints, street_strips)

	return {
		"chunk_coord": chunk_coord,
		"chunk_size": chunk_size,
		"origin": origin,
		"building_footprints": footprints,
		"street_polygon": street_strips,
		"lot_adjacency": _compute_adjacency(footprints, street_width),
	}


## The forced boundary-margin street ring (plan §5 failure mode 1 mitigation): four Rect2 strips,
## each `street_width` wide, forming the chunk's outer edge -- computed so the four strips never
## overlap each other (top/bottom span the full width; left/right fill only the remaining height).
static func _perimeter_strips(origin: Vector2, chunk_size: float, street_width: float) -> Array:
	var s := street_width
	var strips: Array = []
	strips.append(Rect2(origin, Vector2(chunk_size, s)))                                          # top
	strips.append(Rect2(origin + Vector2(0.0, chunk_size - s), Vector2(chunk_size, s)))            # bottom
	strips.append(Rect2(origin + Vector2(0.0, s), Vector2(s, chunk_size - 2.0 * s)))                # left
	strips.append(Rect2(origin + Vector2(chunk_size - s, s), Vector2(s, chunk_size - 2.0 * s)))     # right
	return strips


## Recursive BSP subdivision of `rect` into lots within [lot_min, lot_max] separated by
## `street_width`-wide gutters. Appends leaves into `out_footprints` and every internal gutter Rect2
## into `out_streets` (both passed by reference -- GDScript Array/Dictionary are reference types).
static func _split(rect: Rect2, lot_min: float, lot_max: float, street_width: float,
		rng: RandomNumberGenerator, depth: int, out_footprints: Array, out_streets: Array) -> void:
	var w := rect.size.x
	var h := rect.size.y
	var can_split_w := w >= lot_min * 2.0 + street_width
	var can_split_h := h >= lot_min * 2.0 + street_width
	var within_max := w <= lot_max and h <= lot_max

	if depth >= MAX_SPLIT_DEPTH or not (can_split_w or can_split_h) \
			or (within_max and rng.randf() < STOP_PROBABILITY):
		out_footprints.append({"rect": rect, "id": out_footprints.size()})
		return

	# Split along the longer axis when both CAN split (keeps lots roughly regular, matching the
	# reference's fairly even block grid); fall back to whichever single axis actually can.
	var split_vertical: bool
	if can_split_w and can_split_h:
		split_vertical = w >= h
	else:
		split_vertical = can_split_w

	if split_vertical:
		var max_a: float = w - lot_min - street_width
		var cut: float = rng.randf_range(lot_min, max_a)
		var a := Rect2(rect.position, Vector2(cut, h))
		var b := Rect2(rect.position + Vector2(cut + street_width, 0.0), Vector2(w - cut - street_width, h))
		out_streets.append(Rect2(rect.position + Vector2(cut, 0.0), Vector2(street_width, h)))
		_split(a, lot_min, lot_max, street_width, rng, depth + 1, out_footprints, out_streets)
		_split(b, lot_min, lot_max, street_width, rng, depth + 1, out_footprints, out_streets)
	else:
		var max_a: float = h - lot_min - street_width
		var cut: float = rng.randf_range(lot_min, max_a)
		var a := Rect2(rect.position, Vector2(w, cut))
		var b := Rect2(rect.position + Vector2(0.0, cut + street_width), Vector2(w, h - cut - street_width))
		out_streets.append(Rect2(rect.position + Vector2(0.0, cut), Vector2(w, street_width)))
		_split(a, lot_min, lot_max, street_width, rng, depth + 1, out_footprints, out_streets)
		_split(b, lot_min, lot_max, street_width, rng, depth + 1, out_footprints, out_streets)


## Geometric lot_adjacency: lot A is adjacent to lot B iff A's footprint, grown by
## `street_width * ADJACENCY_MARGIN_FACTOR`, intersects B's footprint -- i.e. they face each other
## across a street/gutter no wider than that margin. O(n^2) over a single chunk's lot count (typically
## a few dozen), which is fine at this scale; a future increment can grid-bucket this if a scene ever
## packs a chunk dense enough for it to matter.
static func _compute_adjacency(footprints: Array, street_width: float) -> Dictionary:
	var adjacency: Dictionary = {}
	for f in footprints:
		adjacency[int(f["id"])] = []
	var margin := street_width * ADJACENCY_MARGIN_FACTOR
	for i in footprints.size():
		var ri: Rect2 = footprints[i]["rect"]
		var expanded: Rect2 = ri.grow(margin)
		for j in range(i + 1, footprints.size()):
			var rj: Rect2 = footprints[j]["rect"]
			if expanded.intersects(rj):
				adjacency[int(footprints[i]["id"])].append(int(footprints[j]["id"]))
				adjacency[int(footprints[j]["id"])].append(int(footprints[i]["id"]))
	return adjacency


## Convenience: a flat-shaded ArrayMesh for one lot's footprint, extruded up by `height` -- the v0
## placeholder box every building volume renders as before BrickWallGenerator (plan node 4, a later
## increment) replaces it with real coursed brick. World-space XZ footprint -> a Y-up box at that XZ,
## base at `base_y`.
static func lot_box_mesh(lot: Dictionary, height: float, base_y: float = 0.0) -> Mesh:
	var rect: Rect2 = lot["rect"]
	var box := BoxMesh.new()
	box.size = Vector3(maxf(0.01, rect.size.x), maxf(0.01, height), maxf(0.01, rect.size.y))
	return box

## World-space center (X, base_y + height/2, Z) for one lot's placeholder box -- the transform a
## caller positions `lot_box_mesh`'s MeshInstance3D at.
static func lot_box_center(lot: Dictionary, height: float, base_y: float = 0.0) -> Vector3:
	var rect: Rect2 = lot["rect"]
	var c := rect.get_center()
	return Vector3(c.x, base_y + height * 0.5, c.y)
