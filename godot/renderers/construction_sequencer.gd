class_name ConstructionSequencer
extends RefCounted
## ConstructionSequencer -- node 2 ("Scaffolding tier") of
## notes/planning/underground_halls_plan_2026_07_14.md §4, Wave 2 item 2.2 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (independently buildable in the same
## lane as the cavity carver, per DQ-6963c689's own text). Wraps
## RingScaffoldGenerator.wedge_chunks()'s emission in a chosen ORDER with a per-chunk delay, so a
## scene visibly grows/constructs itself on regenerate -- "node by node" visible construction
## (plan §2.1). No existing tick-animation precedent was found in the codebase (`wfc_generalized.gd`
## checked directly -- WFC resolves without an exposed per-step animation hook), confirmed
## genuinely new by the plan's own substrate-inventory note (§3, node "Construction-sequencer").
##
## Pure DATA in -> pure DATA out (`order_chunks` sorts a plain Array; `Sequence` is a tick-driven
## emission cursor over that Array), the same portability invariant ScatterComposer/DetailField
## hold: no engine Node/scene-tree/Timer dependency required to CALL this -- a caller (a scene
## driver) owns the actual per-frame or Timer wiring and MeshInstance3D instancing, this module only
## decides WHICH chunk is due WHEN.
##
## Tunables (plan §4 node 2):
##   ordering_mode   : enum "radial-out" | "ring-by-ring" | "angular-sweep". Default "ring-by-ring".
##   tick_interval_ms: int, 10-500. Default 60.

const ORDER_RADIAL_OUT := "radial-out"
const ORDER_RING_BY_RING := "ring-by-ring"
const ORDER_ANGULAR_SWEEP := "angular-sweep"
const ORDERING_MODES := [ORDER_RADIAL_OUT, ORDER_RING_BY_RING, ORDER_ANGULAR_SWEEP]

const DEFAULT_ORDERING_MODE := ORDER_RING_BY_RING
const DEFAULT_TICK_INTERVAL_MS := 60
const MIN_TICK_INTERVAL_MS := 10
const MAX_TICK_INTERVAL_MS := 500


## Sort `chunk_list` (as returned by RingScaffoldGenerator.wedge_chunks(), each a Dictionary with at
## least "ring" and "arc" int fields) into construction ORDER per `ordering_mode`. Returns a NEW
## Array (never mutates `chunk_list`).
##
##   ring-by-ring   -- every wedge of ring 1 (in arc order), then every wedge of ring 2, ... Sort
##                     key (ring, arc). Literally "build the innermost hallway first, then the
##                     next" -- the plan §4 default.
##   radial-out     -- interleaved by ARC POSITION first: arc 0 across every ring (inner to outer),
##                     then arc 1 across every ring, ... Sort key (arc, ring) -- a single "spoke"
##                     sweeps outward at each angular position before advancing to the next angle.
##   angular-sweep  -- every ring advances together, one arc-step at a time. Same sort KEY as
##                     radial-out ((arc, ring)) -- the visible difference between the two modes is
##                     how a CALLER groups ticks (radial-out: one wedge emitted per tick;
##                     angular-sweep: a caller batches a whole ring's wedges into one tick via
##                     `Sequence.advance_batch()` below), not a different data-level sort. Documented
##                     here so that distinction isn't silently lost.
static func order_chunks(chunk_list: Array, ordering_mode: String = DEFAULT_ORDERING_MODE) -> Array:
	var mode := ordering_mode if ordering_mode in ORDERING_MODES else DEFAULT_ORDERING_MODE
	var chunks := chunk_list.duplicate()
	match mode:
		ORDER_RING_BY_RING:
			chunks.sort_custom(_ring_arc_key_asc)
		_:  # ORDER_RADIAL_OUT, ORDER_ANGULAR_SWEEP
			chunks.sort_custom(_arc_ring_key_asc)
	return chunks

static func _ring_arc_key_asc(a: Dictionary, b: Dictionary) -> bool:
	var ra: int = int(a.get("ring", 0))
	var rb: int = int(b.get("ring", 0))
	if ra != rb:
		return ra < rb
	return int(a.get("arc", 0)) < int(b.get("arc", 0))

static func _arc_ring_key_asc(a: Dictionary, b: Dictionary) -> bool:
	var aa: int = int(a.get("arc", 0))
	var ab: int = int(b.get("arc", 0))
	if aa != ab:
		return aa < ab
	return int(a.get("ring", 0)) < int(b.get("ring", 0))


## Clamp `tick_interval_ms` into the plan §4 range (10-500), defaulting to 60 for anything
## non-numeric/unset.
static func clamp_tick_interval(tick_interval_ms) -> int:
	if tick_interval_ms == null:
		return DEFAULT_TICK_INTERVAL_MS
	return clampi(int(tick_interval_ms), MIN_TICK_INTERVAL_MS, MAX_TICK_INTERVAL_MS)


## The tick-driven emission cursor -- node 2's `emission_stream` output ("one event per tick"). A
## caller advances it with real elapsed time (`advance(delta_ms)`) once per frame/timer-tick; it
## returns however many chunks have come due since the last call (0, 1, or several, if `delta_ms`
## spans multiple `tick_interval_ms` steps -- never silently drops a chunk).
##
## `generation_id` is a plain caller-set token (per plan §6 FM-3's "generation-id token on every
## emitted chunk" mitigation, formally the shared ChunkLifecycleManager primitive's job per the
## comparison-pass addendum §10.6 -- this Sequence only CARRIES the token on every emitted event so
## a caller can filter stale emissions after a regenerate; it does not implement chunk lifecycle
## itself, matching §10.6's "both stay wiring-only against the new shared primitive").
class Sequence:
	var ordered: Array
	var ordering_mode: String
	var tick_interval_ms: int
	var generation_id: int
	var cursor: int = 0
	var _elapsed_ms: float = 0.0

	func _init(chunk_list: Array, p_ordering_mode: String = DEFAULT_ORDERING_MODE,
			p_tick_interval_ms = DEFAULT_TICK_INTERVAL_MS, p_generation_id: int = 0) -> void:
		ordering_mode = p_ordering_mode if p_ordering_mode in ORDERING_MODES else DEFAULT_ORDERING_MODE
		tick_interval_ms = ConstructionSequencer.clamp_tick_interval(p_tick_interval_ms)
		generation_id = p_generation_id
		ordered = ConstructionSequencer.order_chunks(chunk_list, ordering_mode)

	func total() -> int:
		return ordered.size()

	func is_done() -> bool:
		return cursor >= ordered.size()

	func progress() -> float:
		if ordered.is_empty():
			return 1.0
		return float(cursor) / float(ordered.size())

	## Advance real time by `delta_ms` and return every chunk that has come due since the previous
	## call, each wrapped as an emission event:
	##   {"chunk": Dictionary, "index": int, "generation_id": int, "is_last": bool}
	## Returns an empty Array once `is_done()`. Never emits more than one event per due chunk even
	## across a very large `delta_ms` (catches up in full, no chunk is ever skipped).
	func advance(delta_ms: float) -> Array:
		var events: Array = []
		if is_done():
			return events
		_elapsed_ms += maxf(0.0, delta_ms)
		while _elapsed_ms >= float(tick_interval_ms) and not is_done():
			_elapsed_ms -= float(tick_interval_ms)
			events.append(_emit_current())
		return events

	## Force-emit exactly `count` chunks regardless of elapsed time (the "angular-sweep" caller
	## pattern -- e.g. a whole ring's wedge count per tick). Resets the internal elapsed-time
	## accumulator so a subsequent `advance()` call starts a fresh interval, avoiding a double-catch-
	## up burst.
	func advance_batch(count: int) -> Array:
		var events: Array = []
		for _i in maxi(0, count):
			if is_done():
				break
			events.append(_emit_current())
		_elapsed_ms = 0.0
		return events

	func _emit_current() -> Dictionary:
		var chunk = ordered[cursor]
		var event := {
			"chunk": chunk, "index": cursor, "generation_id": generation_id,
			"is_last": cursor == ordered.size() - 1,
		}
		cursor += 1
		return event

	## Reset the cursor to the start of the SAME ordered sequence (does not re-sort/re-fetch chunks
	## -- construct a new Sequence for a genuine regenerate with a new `chunk_list`).
	func reset() -> void:
		cursor = 0
		_elapsed_ms = 0.0


## Convenience top-level entry point: order `chunk_list` and wrap it in a fresh Sequence in one
## call, from raw tunables -- the shape a caller (or a future node-graph `ConstructionSequencer`
## node wrapper) consumes.
static func build(chunk_list: Array, tunables: Dictionary = {}) -> Sequence:
	var ordering_mode: String = String(tunables.get("ordering_mode", DEFAULT_ORDERING_MODE))
	var tick_interval_ms = tunables.get("tick_interval_ms", DEFAULT_TICK_INTERVAL_MS)
	var generation_id: int = int(tunables.get("generation_id", 0))
	return Sequence.new(chunk_list, ordering_mode, tick_interval_ms, generation_id)
