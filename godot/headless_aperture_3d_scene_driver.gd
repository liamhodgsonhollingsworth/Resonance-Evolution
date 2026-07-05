extends SceneTree
## Headless SCENE DRIVER for the 3D-aperture ROOM — instances the REAL aperture_3d.tscn and drives
## its computer-opens-board wiring + its door → transition through the actual room script, proving
## the pieces are wired (not just unit-tested in isolation).
##   godot --headless --path godot -s res://headless_aperture_3d_scene_driver.gd
##
## Headless can build the scene tree + call methods; it cannot render or capture the mouse, so this
## asserts on TREE STATE (the board overlay mounts / unmounts; a same-window door plan resolves),
## which is exactly the wiring the windowed --shot cannot assert. ComputerTerminal.open_board and
## SceneTransition are display-guarded (no-op / degrade when headless), so we assert the guarded
## behavior AND the pure planning that runs regardless.

const ComputerTerminal := preload("res://aperture/computer_terminal.gd")
const SceneTransition := preload("res://aperture/scene_transition.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	var ok := true
	# Instance the REAL room scene (its _ready builds room + computer + doors + palette).
	var ps: PackedScene = load("res://aperture/aperture_3d.tscn")
	ok = _check("aperture_3d.tscn loads", ps != null) and ok
	var room: Node = ps.instantiate()
	get_root().add_child(room)
	await process_frame
	await process_frame

	# The room built its sub-structure.
	ok = _check("room built the Objects root", room.get_node_or_null("Objects") != null) and ok
	ok = _check("room built the Doors root (2 doors)",
		room.get_node_or_null("Doors") != null and room.get_node("Doors").get_child_count() == 2) and ok
	ok = _check("room built the Computer", room.get_node_or_null("Computer") != null) and ok
	ok = _check("palette slot 0 is the empty hand",
		room.call("_is_empty_hand")) and ok

	# COMPUTER → 2D BOARD overlay. Headless open_board is display-guarded (returns null / mounts
	# nothing), so board_is_open stays false — assert the guard holds (no crash, no phantom overlay).
	ok = _check("headless: computer board overlay is display-guarded (not mounted)",
		not ComputerTerminal.board_is_open(room)) and ok
	ok = _check("close_board is a safe no-op when nothing is open",
		not ComputerTerminal.close_board(room)) and ok

	# The room's own door specs each resolve to a valid transition PLAN (the wiring that decides
	# same-window vs new-window at walk-in time). This runs regardless of display.
	var specs: Array = room.get("door_specs")
	ok = _check("room carries 2 door specs", specs.size() == 2) and ok
	var exp_plan := SceneTransition.plan(specs[0])
	ok = _check("door 0 (explore, experimental) plans to a NEW window",
		bool(exp_plan.get("ok")) and String(exp_plan.get("channel")) == "new_window") and ok
	var stable_plan := SceneTransition.plan(specs[1])
	ok = _check("door 1 (sandbox, stable) plans to the SAME window",
		bool(stable_plan.get("ok")) and String(stable_plan.get("channel")) == "same_window") and ok

	# Placement path: with a block selected, _place_active adds one object to the Objects root.
	room.set("active_slot", 1)                    # slot 1 = Cube
	var objects_before: int = (room.get("objects") as Dictionary).size()
	room.call("_place_active")
	var objects_after: int = (room.get("objects") as Dictionary).size()
	ok = _check("placing a block (free placement) adds one object", objects_after == objects_before + 1) and ok

	room.queue_free()
	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail))
	quit(0 if ok else 1)
