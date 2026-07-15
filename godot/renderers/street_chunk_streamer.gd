class_name StreetChunkStreamer
extends RefCounted
## StreetChunkStreamer -- node 3 ("ChunkStreamer") of notes/planning/brick_street_scene_plan_2026_07_14.md
## §4, Wave-A1 increment 1. Composes the two ALREADY-MERGED Wave 1 shared primitives --
## `ChunkLifecycleManager` (renderers/chunk_lifecycle.gd, PR #187) and `DetailField.DetailLODTracker`
## (renderers/detail_field.gd, PR #188) -- with `StreetGridScaffold` (this file's own sibling), rather
## than re-deriving spawn/despawn or LOD-tier bookkeeping from scratch. `ChunkLifecycleManager.grid_key_fn`
## is ALREADY the exact grid/lot partition scheme this scene needs -- its own docstring names
## "Project A, brick-street scene" as the intended caller -- so this file is wiring, not a new
## primitive, per the reuse/portability law ("new node, not edit a primitive").
##
## Pure DATA in -> pure DATA out, no scene-tree dependency (same portability invariant as its two
## composed primitives): `update()` returns which street-grid CHUNKS (real `StreetGridScaffold.build()`
## results) should spawn/despawn this frame, keyed the same Vector2i grid cells
## `ChunkLifecycleManager.grid_key_fn` produces; a caller instances/frees its own scene nodes off that
## diff. Per-building LOD-tier decisions are exposed via `lod_tracker` (a shared
## `DetailField.DetailLODTracker`), keyed by `item_id(chunk_key, lot_id)` so every building footprint
## across every live chunk has a stable, collision-free tracker id.

var lod_tracker: DetailField.DetailLODTracker
var chunk_size: float

var _lifecycle: ChunkLifecycleManager
var _world_seed: int
var _packing_seed: int
var _scaffold_params: Dictionary


## `load_radius_cells` is `ChunkLifecycleManager.grid_key_fn`'s own streaming-margin radius (Chebyshev
## cell radius around the player's own chunk -- radius=2 keeps a 5x5 block of chunks live).
## `scaffold_params` optionally overrides `StreetGridScaffold`'s `lot_size_min`/`lot_size_max`/
## `street_width` (any key omitted falls back to `StreetGridScaffold`'s own DEFAULT_* constants).
func _init(world_seed: int, chunk_size_: float = StreetGridScaffold.DEFAULT_CHUNK_SIZE,
		load_radius_cells: int = 2, packing_seed: int = StreetGridScaffold.DEFAULT_PACKING_SEED,
		scaffold_params: Dictionary = {}) -> void:
	_world_seed = world_seed
	_packing_seed = packing_seed
	chunk_size = maxf(1.0, chunk_size_)
	_scaffold_params = scaffold_params
	_lifecycle = ChunkLifecycleManager.new(ChunkLifecycleManager.grid_key_fn(chunk_size, load_radius_cells))
	lod_tracker = DetailField.DetailLODTracker.new()


## Recompute the wanted set of street-grid chunks around `player_pos` and return the diff, generating
## real `StreetGridScaffold` DATA for every NEWLY-spawned chunk only (`ChunkLifecycleManager` already
## deduplicates a still-live chunk, so this never re-solves a chunk that hasn't moved out of range).
## Returns:
##   {
##     "spawn": Array of {"key": Vector2i, "generation": int, "scaffold": Dictionary},
##     "despawn": Array of Vector2i,
##   }
## A caller tearing down a despawned chunk's instanced nodes should also call `lod_tracker.forget()`
## via `item_id()` for each of that chunk's lots (this streamer does not itself retain a live-chunk
## cache, so it cannot enumerate a despawned chunk's own lot ids after the fact -- the caller, which
## instanced them, already has that list).
func update(player_pos: Vector3) -> Dictionary:
	var diff := _lifecycle.update(player_pos)
	var spawn: Array = []
	for key in diff["spawn"]:
		var scaffold: Dictionary = StreetGridScaffold.build(_world_seed, key, chunk_size,
			float(_scaffold_params.get("lot_size_min", StreetGridScaffold.DEFAULT_LOT_SIZE_MIN)),
			float(_scaffold_params.get("lot_size_max", StreetGridScaffold.DEFAULT_LOT_SIZE_MAX)),
			float(_scaffold_params.get("street_width", StreetGridScaffold.DEFAULT_STREET_WIDTH)),
			_packing_seed)
		spawn.append({"key": key, "generation": diff["generation"][key], "scaffold": scaffold})
	return {"spawn": spawn, "despawn": diff["despawn"]}


## True iff (key, generation) is still the CURRENT generation for that chunk -- an in-flight async
## build for a spawned chunk should check this at its yield points and abort if a `mark_dirty()` (a
## param change) has superseded it since. Direct passthrough to `ChunkLifecycleManager.is_current()`.
func is_current(key: Vector2i, generation: int) -> bool:
	return _lifecycle.is_current(key, generation)


func live_chunk_keys() -> Array:
	return _lifecycle.live_keys()


## Stable per-lot LOD-tracker item id: unique across every (chunk, lot) pair currently in play, so
## `lod_tracker.update(item_id(chunk_key, lot_id), ...)` never collides across chunks. Static (not
## instance state) so a caller can compute the same id independently when tearing down a despawned
## chunk's lots, without needing a live StreetChunkStreamer reference.
static func item_id(chunk_key: Vector2i, lot_id: int) -> String:
	return "%d:%d:%d" % [chunk_key.x, chunk_key.y, lot_id]


## Convenience: decide the LOD tier for one building footprint (`lot`, an entry from a chunk's
## `building_footprints`) given the camera/player distance to its center. Wraps
## `DetailField.DetailLODTracker.update()` with the `item_id()` keying convention above.
func lod_tier_for_lot(chunk_key: Vector2i, lot: Dictionary, distance: float, near_distance: float,
		detail: float = 1.0, hysteresis: float = 0.15) -> Dictionary:
	var lot_id := int(lot.get("id", 0))
	return lod_tracker.update(item_id(chunk_key, lot_id), distance, detail, near_distance, hysteresis)
