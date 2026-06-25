extends SceneTree
## Headless verification of proximity-gated PICKUP/INTERACTION (DQ-000092b5), WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_pickup_test.gd
##
## The interaction is built on the existing `proximity` Context handler (prim_context.gd) — this
## test proves the player can ONLY interact (pick up / use) an object once they walk up to it (are
## within the static radius), and that using it removes it from the world + records it in inventory.
## Asserts:
##   (1) PickupInteractor registers live objects as pickable,
##   (2) an object OUT of range is not available (the proximity scope is dormant),
##   (3) an object IN range becomes available (the scope is live) — "walk up to interact",
##   (4) use_nearest() while in range picks it up: removed from world, added to inventory,
##   (5) a picked-up object stays gone (idempotent — can't pick up twice),
##   (6) of two in-range objects, use_nearest() picks the CLOSER one,
##   (7) the real walkabout scene assembles and registers its laid-out assets as pickable.

func _initialize() -> void:
	var ok := true

	# A bare interactor + two pickable objects placed in the world.
	var interactor := PickupInteractor.new()
	get_root().add_child(interactor)
	var apple := Node3D.new()
	apple.name = "apple"
	apple.position = Vector3(0, 0, 0)
	get_root().add_child(apple)
	var rock := Node3D.new()
	rock.name = "rock"
	rock.position = Vector3(0, 0, 10)             # far away
	get_root().add_child(rock)
	# Let the SceneTree compute global transforms before any proximity read (global_position is only
	# valid once the node is in-tree AND a frame has propagated transforms; this mirrors the live
	# scene, where the interactor first reads positions on a real _process frame).
	await process_frame
	interactor.register("apple", apple, 2.5)
	interactor.register("rock", rock, 2.5)

	# (1) registration
	ok = _check("registered 2 pickables", interactor.pickable_count() == 2) and ok

	# (2) player far from both -> nothing available (proximity scope dormant)
	interactor.refresh(Vector3(0, 0, 5))
	ok = _check("nothing available when player is far from all objects",
		interactor.available_ids().is_empty()) and ok

	# (3) player walks up to the apple (within radius) -> apple available, rock still not
	interactor.refresh(Vector3(0, 0, 1.0))
	var avail := interactor.available_ids()
	ok = _check("apple becomes available when player walks within radius", avail.has("apple")) and ok
	ok = _check("distant rock stays unavailable", not avail.has("rock")) and ok

	# (4) use it -> picked up: gone from world (hidden), recorded in inventory
	var picked := interactor.use_nearest(Vector3(0, 0, 1.0))
	ok = _check("use_nearest picks up the in-range apple", picked == "apple") and ok
	ok = _check("picked-up apple is removed from the world (not visible)", not apple.visible) and ok
	ok = _check("inventory records the pickup", interactor.inventory() == ["apple"]) and ok

	# (5) can't pick it up again (it's gone)
	interactor.refresh(Vector3(0, 0, 1.0))
	ok = _check("apple is no longer available after pickup", not interactor.available_ids().has("apple")) and ok
	ok = _check("re-using picks up nothing (apple already taken)",
		interactor.use_nearest(Vector3(0, 0, 1.0)) == "") and ok

	# (6) nearest-of-two: two objects in range -> the closer is chosen
	var near := Node3D.new(); near.position = Vector3(0, 0, 0); get_root().add_child(near)
	var far := Node3D.new(); far.position = Vector3(0, 0, 1.5); get_root().add_child(far)
	await process_frame
	var pick2 := PickupInteractor.new(); get_root().add_child(pick2)
	pick2.register("near", near, 5.0)
	pick2.register("far", far, 5.0)
	pick2.refresh(Vector3(0, 0, -0.2))
	ok = _check("both in range", pick2.available_ids().size() == 2) and ok
	ok = _check("use_nearest picks the CLOSER object", pick2.use_nearest(Vector3(0, 0, -0.2)) == "near") and ok

	# (7) the REAL walkabout scene assembles and registers laid-out assets as pickable
	var scene: PackedScene = load("res://walkabout/walkabout.tscn")
	ok = _check("walkabout scene loads", scene != null) and ok
	if scene != null:
		var wk := scene.instantiate()
		get_root().add_child(wk)
		await process_frame                   # let _ready build world + render + register
		var inter = wk.get_node_or_null("PickupInteractor")
		ok = _check("walkabout created a PickupInteractor", inter != null) and ok
		if inter != null:
			ok = _check("walkabout registered >=1 pickable from its laid-out assets",
				inter.pickable_count() >= 1) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
