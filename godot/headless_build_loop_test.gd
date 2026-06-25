extends SceneTree
## Headless verification of the MODULAR-BUILDING LOOP (DQ-4f47fab6): inventory + place-down, WITHOUT
## a window.
##
##   <godot> --headless --path godot -s res://headless_build_loop_test.gd
##
## The loop is pick-up (E) + place-down (Q). This test drives the pure methods directly (no input
## device): it picks an object up, confirms it lands in the type-grouped inventory, PLACES it back
## into the world, and confirms the placed object registers as a real scene Node3D at the expected
## grid-snapped position AND is re-pickable. Asserts:
##   (1) register-with-descriptor records the object's inventory TYPE,
##   (2) pick-up increments the held count for that type + selects it,
##   (3) held_rows()/held_total() report the inventory the HUD reads,
##   (4) place_at() spawns a live Node3D in the world from the stored descriptor,
##   (5) the placed object sits at the requested position,
##   (6) placing decrements the held count (inventory is consumed),
##   (7) the placed object is registered back as a fresh pickable (loop closes: place -> pick),
##   (8) place_target() grid-snaps a ground-plane fallback point (headless-safe path),
##   (9) cycle_selection() moves the active type across multiple held types,
##  (10) the real walkabout scene assembles, registers descriptor-carrying pickables, and builds a HUD.

const GLB_A := "res://assets/vendor/_test_a.glb"   # synthetic mesh paths — only their IDENTITY matters
const GLB_B := "res://assets/vendor/_test_b.glb"   # to the inventory (no GLB is loaded in this test)

func _initialize() -> void:
	var ok := true
	var world := Node3D.new()
	get_root().add_child(world)

	var interactor := PickupInteractor.new()
	world.add_child(interactor)
	interactor.set_world_root(world)

	# Two distinct-type objects in the world (descriptors carry different mesh paths => different types).
	var obj_a := Node3D.new(); obj_a.name = "bed"; obj_a.position = Vector3(0, 0, 0)
	world.add_child(obj_a)
	var obj_b := Node3D.new(); obj_b.name = "tree"; obj_b.position = Vector3(0, 0, 1.0)
	world.add_child(obj_b)
	await process_frame   # let global transforms propagate before any proximity read

	var desc_a := _descriptor("bed", GLB_A, Vector3(0, 0, 0))
	var desc_b := _descriptor("tree", GLB_B, Vector3(0, 0, 1.0))
	interactor.register("bed_0", obj_a, 2.5, desc_a)
	interactor.register("tree_0", obj_b, 2.5, desc_b)

	# (1) registration recorded a distinct inventory type per object (keyed by mesh).
	ok = _check("two pickables registered", interactor.pickable_count() == 2) and ok
	ok = _check("nothing held before any pickup", interactor.held_total() == 0) and ok

	# (2) pick up the bed -> its type is held x1 and becomes selected.
	interactor.refresh(Vector3(0, 0, 0))
	var picked := interactor.use_nearest(Vector3(0, 0, 0))
	ok = _check("picked up the bed", picked == "bed_0") and ok
	var bed_type := GodotSceneRenderer.mesh_key(desc_a.get("mesh"))
	ok = _check("bed type held x1", interactor.held_count(bed_type) == 1) and ok
	ok = _check("bed type auto-selected", interactor.selected_type() == bed_type) and ok

	# (3) the inventory rows the HUD reads.
	var rows: Array = interactor.held_rows()
	ok = _check("one inventory row after one pickup", rows.size() == 1) and ok
	ok = _check("row reports count 1", rows.size() == 1 and int(rows[0]["count"]) == 1) and ok
	ok = _check("row flagged selected", rows.size() == 1 and bool(rows[0]["selected"])) and ok
	ok = _check("held_total == 1", interactor.held_total() == 1) and ok

	# (4)+(5) PLACE the bed at a target position -> a live Node3D spawns in the world there.
	var children_before := world.get_child_count()
	var target := Vector3(4.0, 0.0, -3.0)
	var placed_id := interactor.place_at(bed_type, target)
	ok = _check("place_at returned a new id", placed_id != "") and ok
	ok = _check("world gained a child node from the placement", world.get_child_count() == children_before + 1) and ok
	# The placed node is named via the descriptor's "name", not the placed id — locate it by position.
	var placed := _node_at(world, target)
	ok = _check("a live Node3D sits at the placement position", placed != null) and ok
	if placed != null:
		ok = _check("placed object is at the requested position",
			placed.global_position.distance_to(target) < 0.001) and ok

	# (6) placing consumed one from inventory.
	ok = _check("bed type held count back to 0 after placing", interactor.held_count(bed_type) == 0) and ok
	ok = _check("held_total back to 0", interactor.held_total() == 0) and ok

	# (7) the placed object is registered back as a fresh pickable (the loop closes).
	ok = _check("placed object re-registered as a pickable (3 total)", interactor.pickable_count() == 3) and ok
	await process_frame
	interactor.refresh(target)   # stand on the placed object
	ok = _check("the placed object can be picked up again", not interactor.available_ids().is_empty()) and ok

	# (8) place_target grid-snaps a ground-plane fallback (headless: no camera -> fallback path).
	var fake_player := Node3D.new()
	world.add_child(fake_player)
	fake_player.global_position = Vector3(0.4, 1.0, 0.0)
	await process_frame
	var tp := interactor.place_target(fake_player, null, 3.3, 1.0)
	ok = _check("place_target snaps to the 1m grid (x integral)", absf(tp.x - roundf(tp.x)) < 0.001) and ok
	ok = _check("place_target snaps to the 1m grid (z integral)", absf(tp.z - roundf(tp.z)) < 0.001) and ok
	ok = _check("place_target drops onto the ground plane (y >= 0)", tp.y >= 0.0) and ok

	# (9) cycle_selection across multiple held types.
	var pick2 := PickupInteractor.new()
	world.add_child(pick2)
	var ca := Node3D.new(); ca.position = Vector3(0, 0, 0); world.add_child(ca)
	var cb := Node3D.new(); cb.position = Vector3(0, 0, 0.5); world.add_child(cb)
	await process_frame
	pick2.register("a", ca, 5.0, _descriptor("alpha", GLB_A, Vector3.ZERO))
	pick2.register("b", cb, 5.0, _descriptor("beta", GLB_B, Vector3(0, 0, 0.5)))
	pick2.refresh(Vector3(0, 0, 0.1))
	pick2.use_nearest(Vector3(0, 0, 0.1))
	pick2.refresh(Vector3(0, 0, 0.5))
	pick2.use_nearest(Vector3(0, 0, 0.5))
	ok = _check("two distinct types held", pick2.held_rows().size() == 2) and ok
	var first_sel := pick2.selected_type()
	var next_sel := pick2.cycle_selection(1)
	ok = _check("cycle_selection moved to a different type", next_sel != first_sel and next_sel != "") and ok
	var wrapped := pick2.cycle_selection(1)
	ok = _check("cycle_selection wraps back", wrapped == first_sel) and ok

	# (10) the REAL walkabout scene assembles, registers descriptor-carrying pickables, builds the HUD.
	var scene: PackedScene = load("res://walkabout/walkabout.tscn")
	ok = _check("walkabout scene loads", scene != null) and ok
	if scene != null:
		var wk := scene.instantiate()
		get_root().add_child(wk)
		await process_frame
		var inter = wk.get_node_or_null("PickupInteractor")
		ok = _check("walkabout created a PickupInteractor", inter != null) and ok
		var hud = wk.get_node_or_null("BuildHud")
		ok = _check("walkabout created a BuildHud", hud != null) and ok
		if inter != null:
			ok = _check("walkabout registered >=1 pickable", inter.pickable_count() >= 1) and ok
			# Pick up + place one of the scene's real laid-out objects end to end.
			var rt := _pick_and_place_one(inter, wk)
			ok = _check("end-to-end pick + place on a real scene object", rt) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

## Walk the interactor: find any registered object, teleport-refresh onto it, pick it up, then place
## it and confirm a live node lands at the grid-snapped target. Returns true on full success.
func _pick_and_place_one(inter, wk) -> bool:
	# Find a registered object's world position by scanning the renderer (a GodotSceneRenderer child).
	var any_pos := Vector3.ZERO
	var found := false
	for c in wk.get_children():
		if c is GodotSceneRenderer:
			for obj in c.get_children():
				if obj is Node3D:
					any_pos = obj.global_position
					found = true
					break
		if found:
			break
	if not found:
		return false
	inter.refresh(any_pos)
	if inter.available_ids().is_empty():
		return false
	var before: int = inter.held_total()
	var pid: String = inter.use_nearest(any_pos)
	if pid == "" or int(inter.held_total()) != before + 1:
		return false
	var t := Vector3(7.0, 0.0, 7.0)
	var placed_id: String = inter.place_at(inter.selected_type(), t)
	if placed_id == "":
		return false
	var placed := _node_at(wk, t)
	return placed != null and placed.global_position.distance_to(t) < 0.001

# --- helpers ----------------------------------------------------------------------------------

func _descriptor(name: String, glb_path: String, pos: Vector3) -> Dictionary:
	return {
		"name": name,
		"translation": [pos.x, pos.y, pos.z],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": { "source": "glb", "path": glb_path },
		"children": []
	}

## First Node3D in `root`'s subtree whose global_position is at `pos` (within 1mm) — used to confirm
## a placed object actually landed where requested.
func _node_at(root: Node, pos: Vector3) -> Node3D:
	for c in root.get_children():
		if c is Node3D and (c as Node3D).global_position.distance_to(pos) < 0.001:
			return c
		var nested := _node_at(c, pos)
		if nested != null:
			return nested
	return null

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
