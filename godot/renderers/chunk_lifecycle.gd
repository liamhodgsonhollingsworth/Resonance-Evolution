class_name ChunkLifecycleManager
extends RefCounted
## ChunkLifecycleManager — Wave 1 item 1.3 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (reframe of
## Project A's node 3 `ChunkStreamer`, shared with Project B's nodes 2/16):
## "`chunk_key_fn(camera_or_player_pos) -> Set[chunk_key]`,
## partition-scheme-parameterized (grid/lot keys for the brick-street scene,
## ring/arc-segment keys for the underground-halls scene); spawn/despawn
## events + a generation-id token per emitted chunk so an in-flight regen can
## be cancelled, not queued, on a new param change."
##
## PARTITION-SCHEME-AGNOSTIC by construction: the caller supplies
## `chunk_key_fn`, a Callable that maps a world position to the Array of
## chunk keys that should be live around it. A chunk key can be ANY hashable
## Variant a caller wants (Vector2i for a street grid, a small Dictionary
## like `{"ring": 3, "arc": 7}` for a ring/arc-segment partition) — this
## manager only ever compares keys for equality via Dictionary lookups, never
## interprets their shape. Same portability invariant as DetailField /
## ScatterComposer: pure DATA in (a position + a key function), pure DATA out
## (spawn/despawn key lists + generation tokens); no scene-tree dependency.
##
## Generation-id contract (the correctness property this module exists to
## provide, per the plan text): every chunk key currently tracked carries a
## monotonically increasing generation counter. A NEW SPAWN starts a chunk at
## generation 0. A PARAM CHANGE that should invalidate in-flight regeneration
## work for a chunk (`mark_dirty()`) bumps that chunk's generation. A
## long-running async/background regen task for (key, generation) can check
## `is_current(key, generation)` at any yield point and abort — rather than
## finish and get queued behind a newer regen — the moment a caller-side
## `mark_dirty()` supersedes it. This is what closes Project B's own FM-2/
## FM-3 "reuse observer's stay-live behavior" gap that its plan assumed but
## never implemented (comparison-pass finding, §1.1 of the transfer matrix).

var _chunk_key_fn: Callable
var _live: Dictionary = {}       # key -> generation:int, currently spawned
var _next_generation: Dictionary = {}  # key -> next generation to hand out


func _init(chunk_key_fn: Callable) -> void:
	assert(chunk_key_fn.is_valid(), "ChunkLifecycleManager requires a valid chunk_key_fn")
	_chunk_key_fn = chunk_key_fn


## Recompute the wanted chunk-key set for `pos` (via `chunk_key_fn`) against
## the currently-live set, and return the diff:
##
##   {
##     "spawn":   Array of NEW keys that should now be instantiated,
##     "despawn": Array of keys that should now be torn down,
##     "generation": Dictionary key -> int, the CURRENT generation for every
##                    key in "spawn" (always 0 for a first-time spawn; carries
##                    forward the existing generation if a key was despawned
##                    and re-requested before this manager forgot it — it
##                    doesn't, today, forget on despawn, so this is always the
##                    live generation) — a spawn caller should tag whatever it
##                    instantiates with this token and check `is_current()`
##                    before it finishes writing the chunk into the world.
##   }
##
## Calling `update()` also commits the new live set: a key present in
## "spawn" is live after this call; a key present in "despawn" is not.
func update(pos: Vector3) -> Dictionary:
	var wanted: Dictionary = {}  # key -> true, dedup the caller's returned array
	for key in _chunk_key_fn.call(pos):
		wanted[key] = true

	var spawn: Array = []
	var despawn: Array = []
	var generation: Dictionary = {}

	for key in wanted:
		if not _live.has(key):
			var gen: int = _next_generation.get(key, 0)
			_live[key] = gen
			_next_generation[key] = gen + 1
			spawn.append(key)
		generation[key] = _live[key]

	for key in _live.keys():
		if not wanted.has(key):
			despawn.append(key)

	for key in despawn:
		_live.erase(key)

	return {"spawn": spawn, "despawn": despawn, "generation": generation}


## Bump the generation token for `keys` (or every currently-live key if
## `keys` is empty) WITHOUT despawning them — signals "a param changed;
## whatever is regenerating this chunk right now is stale." Returns the new
## generation for each bumped key (Dictionary key -> int) so a caller that
## wants to kick off a fresh regen immediately can tag it with the right
## token in the same call.
func mark_dirty(keys: Array = []) -> Dictionary:
	var targets: Array = keys if not keys.is_empty() else _live.keys()
	var bumped: Dictionary = {}
	for key in targets:
		if not _live.has(key):
			continue
		var gen: int = _next_generation.get(key, 1)
		_live[key] = gen
		_next_generation[key] = gen + 1
		bumped[key] = gen
	return bumped


## True iff `key` is still live AND `generation` is still its current
## generation — i.e. no `mark_dirty()` / respawn has superseded it since the
## caller was handed this token. An in-flight regen task should call this at
## its yield points and abort as soon as it returns false.
func is_current(key, generation: int) -> bool:
	return _live.has(key) and _live[key] == generation


## The generation currently assigned to `key`, or -1 if `key` is not live.
func generation_of(key) -> int:
	return _live.get(key, -1)


## Every currently-live chunk key (Array, snapshot — mutating it does not
## affect this manager's internal state).
func live_keys() -> Array:
	return _live.keys()


## ---------------------------------------------------------------------
## Built-in chunk_key_fn factories for the two partition schemes named in
## the spec text. Both are static so callers can use them directly as the
## `chunk_key_fn` passed to `_init()`, or as a reference implementation.
## ---------------------------------------------------------------------

## Grid/lot partition (Project A, brick-street scene): returns every
## Vector2i grid cell within `radius_cells` (Chebyshev/square radius) of the
## position, in a `cell_size`-sized XZ grid. `radius_cells=1` returns a 3x3
## block of cells centered on the position's own cell.
static func grid_key_fn(cell_size: float, radius_cells: int) -> Callable:
	return func(pos: Vector3) -> Array:
		var cx := int(floor(pos.x / cell_size))
		var cz := int(floor(pos.z / cell_size))
		var out: Array = []
		for dz in range(-radius_cells, radius_cells + 1):
			for dx in range(-radius_cells, radius_cells + 1):
				out.append(Vector2i(cx + dx, cz + dz))
		return out


## Ring/arc-segment partition (Project B, underground-halls scene): the
## scene is concentric rings at radii `n * ring_spacing` (n = 1, 2, 3, ...),
## each ring divided into arc-segment wedges of `arc_deg` degrees (matching
## §2.1's "arc-segment wedges" chunking, candidate default 15-20 deg). Given
## a world position, returns the key of the ring/arc cell containing it PLUS
## `ring_margin` rings inward/outward and `arc_margin` wedges either side —
## the streaming margin so neighboring chunks are already live before the
## player's radius/angle crosses the boundary. Each key is a small
## Dictionary `{"ring": int, "arc": int}` (ring index >= 1; ring 0 — the
## center — is never emitted).
static func ring_key_fn(ring_spacing: float, arc_deg: float,
		ring_margin: int = 1, arc_margin: int = 1) -> Callable:
	var segments_per_ring: int = maxi(1, int(round(360.0 / arc_deg)))
	return func(pos: Vector3) -> Array:
		var r := Vector2(pos.x, pos.z).length()
		var ring := int(round(r / ring_spacing))
		if ring < 1:
			ring = 1
		var theta_deg := fposmod(rad_to_deg(atan2(pos.z, pos.x)), 360.0)
		var arc := int(floor(theta_deg / arc_deg))
		var out: Array = []
		for dr in range(-ring_margin, ring_margin + 1):
			var rr := ring + dr
			if rr < 1:
				continue
			for da in range(-arc_margin, arc_margin + 1):
				var aa := posmod(arc + da, segments_per_ring)
				out.append({"ring": rr, "arc": aa})
		return out
