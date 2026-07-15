extends SceneTree
## Headless test suite for renderers/chunk_lifecycle.gd (Wave 1 item 1.3):
##
##   godot --headless --path godot -s res://test_chunk_lifecycle.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_initial_spawn() and ok
	ok = _test_move_spawns_and_despawns() and ok
	ok = _test_generation_starts_at_zero_and_persists() and ok
	ok = _test_mark_dirty_bumps_generation() and ok
	ok = _test_is_current_false_after_dirty() and ok
	ok = _test_mark_dirty_specific_keys_only() and ok
	ok = _test_generation_of_unknown_key() and ok
	ok = _test_grid_key_fn_3x3_block() and ok
	ok = _test_ring_key_fn_center_and_margins() and ok
	ok = _test_ring_key_fn_wraps_arc_index() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _fixed_keys(keys: Array) -> Callable:
	return func(_pos: Vector3) -> Array:
		return keys


func _test_initial_spawn() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([Vector2i(0, 0), Vector2i(1, 0)]))
	var diff := mgr.update(Vector3.ZERO)
	var spawn: Array = diff["spawn"]
	var despawn: Array = diff["despawn"]
	return _check("initial update: spawns all wanted keys, despawns none",
		spawn.size() == 2 and despawn.is_empty()
		and Vector2i(0, 0) in spawn and Vector2i(1, 0) in spawn)


func _test_move_spawns_and_despawns() -> bool:
	# GDScript lambdas capture local variables BY VALUE at creation time —
	# reassigning `wanted` after the Callable is built would NOT be visible
	# to it. Use an Array MUTATED in place (clear + append_array) instead of
	# reassigned, since Array is a reference type and the closure holds a
	# reference to the same object; this is also why chunk_lifecycle.gd's
	# own implementation avoids closures over mutable state entirely (see
	# its header comment).
	var wanted: Array = [Vector2i(1, 0)]
	var mgr := ChunkLifecycleManager.new(func(_pos: Vector3) -> Array: return wanted)
	mgr.update(Vector3.ZERO)  # live = {(1,0)}

	wanted.clear()
	wanted.append_array([Vector2i(1, 0), Vector2i(2, 0)])
	var diff := mgr.update(Vector3.ZERO)
	var ok: bool = (diff["spawn"] as Array).size() == 1 and (Vector2i(2, 0) in diff["spawn"]) \
		and (diff["despawn"] as Array).is_empty()

	wanted.clear()
	wanted.append(Vector2i(2, 0))
	var diff2 := mgr.update(Vector3.ZERO)
	ok = ok and (diff2["despawn"] as Array).size() == 1 and (Vector2i(1, 0) in diff2["despawn"])
	ok = ok and mgr.live_keys().size() == 1 and (Vector2i(2, 0) in mgr.live_keys())
	return _check("move: spawns newly-wanted keys, despawns no-longer-wanted keys", ok)


func _test_generation_starts_at_zero_and_persists() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([Vector2i(5, 5)]))
	var diff := mgr.update(Vector3.ZERO)
	var gen0_ok: bool = (diff["generation"] as Dictionary)[Vector2i(5, 5)] == 0
	var diff2 := mgr.update(Vector3.ZERO)  # same wanted set, no respawn
	var gen_persists: bool = (diff2["generation"] as Dictionary)[Vector2i(5, 5)] == 0 \
		and mgr.generation_of(Vector2i(5, 5)) == 0
	return _check("generation: starts at 0, persists across no-op updates", gen0_ok and gen_persists)


func _test_mark_dirty_bumps_generation() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([Vector2i(0, 0)]))
	mgr.update(Vector3.ZERO)
	var bumped := mgr.mark_dirty([Vector2i(0, 0)])
	var ok: bool = bumped[Vector2i(0, 0)] == 1 and mgr.generation_of(Vector2i(0, 0)) == 1
	mgr.mark_dirty([Vector2i(0, 0)])
	ok = ok and mgr.generation_of(Vector2i(0, 0)) == 2
	return _check("mark_dirty: bumps generation monotonically (0 -> 1 -> 2)", ok)


func _test_is_current_false_after_dirty() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([Vector2i(0, 0)]))
	var diff := mgr.update(Vector3.ZERO)
	var token: int = (diff["generation"] as Dictionary)[Vector2i(0, 0)]
	var current_before := mgr.is_current(Vector2i(0, 0), token)
	mgr.mark_dirty([Vector2i(0, 0)])
	var current_after := mgr.is_current(Vector2i(0, 0), token)
	return _check("is_current: true before dirty, false for a stale token after dirty",
		current_before and not current_after)


func _test_mark_dirty_specific_keys_only() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([Vector2i(0, 0), Vector2i(1, 1)]))
	mgr.update(Vector3.ZERO)
	mgr.mark_dirty([Vector2i(0, 0)])
	return _check("mark_dirty: only bumps the specified key, not siblings",
		mgr.generation_of(Vector2i(0, 0)) == 1 and mgr.generation_of(Vector2i(1, 1)) == 0)


func _test_generation_of_unknown_key() -> bool:
	var mgr := ChunkLifecycleManager.new(_fixed_keys([]))
	return _check("generation_of: -1 for a key that was never live",
		mgr.generation_of(Vector2i(99, 99)) == -1
		and not mgr.is_current(Vector2i(99, 99), 0))


func _test_grid_key_fn_3x3_block() -> bool:
	var fn := ChunkLifecycleManager.grid_key_fn(10.0, 1)
	var keys: Array = fn.call(Vector3(15.0, 0.0, 25.0))  # cell (1, 2)
	var ok := keys.size() == 9
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			ok = ok and (Vector2i(1 + dx, 2 + dz) in keys)
	return _check("grid_key_fn: 3x3 block centered on the containing cell (%d keys)" % keys.size(), ok)


func _test_ring_key_fn_center_and_margins() -> bool:
	var fn := ChunkLifecycleManager.ring_key_fn(5.0, 20.0, 1, 1)  # 18 arc segments/ring
	# radius 10 -> ring 2; theta 0 deg -> arc 0
	var keys: Array = fn.call(Vector3(10.0, 0.0, 0.0))
	var has_center := {"ring": 2, "arc": 0} in keys
	var has_ring_margin := ({"ring": 1, "arc": 0} in keys) and ({"ring": 3, "arc": 0} in keys)
	var no_ring_zero := true
	for k in keys:
		if k["ring"] < 1:
			no_ring_zero = false
	return _check("ring_key_fn: center ring/arc + ring margins present, never emits ring 0",
		has_center and has_ring_margin and no_ring_zero)


func _test_ring_key_fn_wraps_arc_index() -> bool:
	var fn := ChunkLifecycleManager.ring_key_fn(5.0, 20.0, 0, 1)  # 18 segments, indices 0..17
	# theta ~ 5 deg -> arc 0; arc_margin 1 -> arcs {17 (wrapped), 0, 1}
	var keys: Array = fn.call(Vector3(10.0 * cos(deg_to_rad(5.0)), 0.0, 10.0 * sin(deg_to_rad(5.0))))
	var arcs: Array = []
	for k in keys:
		arcs.append(k["arc"])
	return _check("ring_key_fn: arc index wraps modulo segment count (arcs=%s)" % [arcs],
		17 in arcs and 0 in arcs and 1 in arcs and arcs.size() == 3)
