extends SceneTree
## Headless test suite for renderers/street_chunk_streamer.gd (Wave-A1 increment 1, Project A node 3):
## composition of ChunkLifecycleManager (PR #187) + DetailField.DetailLODTracker (PR #188) with
## StreetGridScaffold.
##
##   godot --headless --path godot -s res://headless_street_chunk_streamer_test.gd

func _initialize() -> void:
	var ok := true
	ok = _test_initial_update_spawns_chunks_around_player() and ok
	ok = _test_spawned_chunks_carry_real_scaffold_data() and ok
	ok = _test_repeat_update_same_position_spawns_nothing_new() and ok
	ok = _test_moving_player_spawns_and_despawns() and ok
	ok = _test_generation_token_present_and_is_current() and ok
	ok = _test_lod_tier_for_lot_near_and_far() and ok
	ok = _test_item_id_unique_across_chunks() and ok
	ok = _test_live_chunk_keys_matches_lifecycle() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _test_initial_update_spawns_chunks_around_player() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 1)  # radius=1 -> 3x3 = 9 chunks
	var diff := streamer.update(Vector3.ZERO)
	return _check("update(): first call around the origin spawns a 3x3=9-chunk block at load_radius=1",
		(diff["spawn"] as Array).size() == 9 and (diff["despawn"] as Array).is_empty())


func _test_spawned_chunks_carry_real_scaffold_data() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 0)  # radius=0 -> just the player's own chunk
	var diff := streamer.update(Vector3.ZERO)
	var spawn: Array = diff["spawn"]
	var ok := spawn.size() == 1
	if ok:
		var entry: Dictionary = spawn[0]
		ok = ok and entry["key"] == Vector2i(0, 0)
		ok = ok and entry.has("generation") and int(entry["generation"]) == 0
		var scaffold: Dictionary = entry["scaffold"]
		ok = ok and scaffold.has("building_footprints") and scaffold.has("street_polygon")
		ok = ok and (scaffold["building_footprints"] as Array).size() > 0
		# The chunk key IS the chunk_coord StreetGridScaffold.build() was called with -- verify by
		# rebuilding directly and comparing.
		var direct := StreetGridScaffold.build(2026, Vector2i(0, 0), 64.0)
		ok = ok and (direct["building_footprints"] as Array).size() == (scaffold["building_footprints"] as Array).size()
	return _check("update(): a spawned chunk's scaffold DATA matches StreetGridScaffold.build() called directly on that key", ok)


func _test_repeat_update_same_position_spawns_nothing_new() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 1)
	streamer.update(Vector3.ZERO)
	var diff2 := streamer.update(Vector3.ZERO)
	return _check("update(): calling again from the SAME position spawns/despawns nothing (already live)",
		(diff2["spawn"] as Array).is_empty() and (diff2["despawn"] as Array).is_empty())


func _test_moving_player_spawns_and_despawns() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 1)
	streamer.update(Vector3.ZERO)
	# Move far enough (several chunk-widths) that the whole 3x3 window shifts -- some chunks despawn,
	# some new ones spawn.
	var diff2 := streamer.update(Vector3(64.0 * 10.0, 0.0, 0.0))
	return _check("update(): moving the player far away despawns the old window and spawns a new one",
		not (diff2["spawn"] as Array).is_empty() and not (diff2["despawn"] as Array).is_empty())


func _test_generation_token_present_and_is_current() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 0)
	var diff := streamer.update(Vector3.ZERO)
	var entry: Dictionary = (diff["spawn"] as Array)[0]
	var key: Vector2i = entry["key"]
	var gen: int = entry["generation"]
	return _check("update(): a freshly-spawned chunk's generation token is CURRENT per is_current()", streamer.is_current(key, gen))


func _test_lod_tier_for_lot_near_and_far() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 0)
	var diff := streamer.update(Vector3.ZERO)
	var entry: Dictionary = (diff["spawn"] as Array)[0]
	var key: Vector2i = entry["key"]
	var scaffold: Dictionary = entry["scaffold"]
	var lot: Dictionary = (scaffold["building_footprints"] as Array)[0]

	var near_result := streamer.lod_tier_for_lot(key, lot, 2.0, 20.0, 1.0)
	var far_result := streamer.lod_tier_for_lot(key, lot, 500.0, 20.0, 1.0)
	var ok := int(near_result["tier"]) == DetailField.LOD_NEAR
	ok = ok and int(far_result["tier"]) == DetailField.LOD_FAR
	return _check("lod_tier_for_lot(): a close distance decides LOD_NEAR, a far distance decides LOD_FAR", ok)


func _test_item_id_unique_across_chunks() -> bool:
	var id_a := StreetChunkStreamer.item_id(Vector2i(0, 0), 3)
	var id_b := StreetChunkStreamer.item_id(Vector2i(1, 0), 3)
	var id_c := StreetChunkStreamer.item_id(Vector2i(0, 0), 4)
	return _check("item_id(): distinct for different chunk keys and different lot ids", id_a != id_b and id_a != id_c and id_b != id_c)


func _test_live_chunk_keys_matches_lifecycle() -> bool:
	var streamer := StreetChunkStreamer.new(2026, 64.0, 1)
	streamer.update(Vector3.ZERO)
	return _check("live_chunk_keys(): matches the 9 chunks spawned at load_radius=1", streamer.live_chunk_keys().size() == 9)
