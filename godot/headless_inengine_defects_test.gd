extends SceneTree
## PROOF of the 6 in-engine defects Liam reported via F1 / scene notes (2026-07-05), each verified by
## an automated text-equivalent assert (the mandatory verify-before-handover gate). Run:
##   <godot> --headless --path godot -s res://headless_inengine_defects_test.gd

const InputGate := preload("res://walkabout/input_gate.gd")
const FpsControllerScript := preload("res://walkabout/fps_controller.gd")
const ExploreScript := preload("res://examples/explore/explore_scene_demo.gd")
const SandboxScene := preload("res://examples/sandbox_creative.tscn")

var _pass := 0
var _fail := 0

func _initialize() -> void:
	await _t1_no_controls_text()
	await _t2_esc_note_stays()
	await _t3_typing_no_move()
	await _t4_inventory_drag()
	await _t5_esc_inventory_stays()
	await _t6_kaykit_can_move()
	print("\nRESULT: %s  (%d passed, %d failed)" % ["ALL PASS" if _fail == 0 else "FAILURES", _pass, _fail])
	quit(0 if _fail == 0 else 1)

func _check(nm: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PASS ", nm)
	else:
		_fail += 1
		print("FAIL ", nm)

# ---- 1: no controls-explanation text overlay ------------------------------------------------------
func _t1_no_controls_text() -> void:
	print("\n== defect 1: no controls-explanation overlay ==")
	var sb: Node = SandboxScene.instantiate()
	get_root().add_child(sb)
	await process_frame
	await process_frame
	var banned := ["WASD", "LEFT destroy", "MIDDLE pick", "E inventory", "Q drop", "mouse look", "RIGHT place"]
	var found := _find_controls_text(sb, banned)
	_check("sandbox has NO controls-explanation text on screen", found == "")
	if found != "":
		print("   offending text: ", found)
	sb.queue_free()
	await process_frame
	var ex: Node = ExploreScript.new()
	get_root().add_child(ex)
	ex.set("_slug", "kaykit_dungeon")
	ex.call("_enter_scene", "kaykit_dungeon")
	for i in 6:
		await process_frame
	var ef := _find_controls_text(ex, ["WASD", "E grab", "leave a note", "mouse look"])
	_check("explore/kaykit has NO controls-explanation text on screen", ef == "")
	if ef != "":
		print("   offending text: ", ef)
	ex.queue_free()
	await process_frame

func _find_controls_text(root: Node, banned: Array) -> String:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label or n is Button:
			var c := n as Control
			if c.is_visible_in_tree() and ("text" in c):
				var txt := String(c.get("text"))
				for b in banned:
					if txt.contains(String(b)):
						return txt
		for ch in n.get_children():
			stack.append(ch)
	return ""

# ---- 2: ESC in the note box does not leave the scene ----------------------------------------------
func _t2_esc_note_stays() -> void:
	print("\n== defect 2: ESC in note box stays in scene ==")
	var gn = get_root().get_node_or_null("/root/GizmoNote")
	_check("GizmoNote autoload present", gn != null)
	if gn == null:
		return
	gn.set("_open", true)
	_check("input_gate.scene_holds_esc TRUE while note open", InputGate.scene_holds_esc(self))
	gn.set("_open", false)
	gn.set("_esc_consumed_frame", Engine.get_process_frames())
	_check("scene_holds_esc TRUE on the frame the note consumed ESC", InputGate.scene_holds_esc(self))
	gn.set("_esc_consumed_frame", -1)
	_check("scene_holds_esc FALSE when note closed + no field focused", not InputGate.scene_holds_esc(self))

# ---- 3: typing does not move the character --------------------------------------------------------
func _t3_typing_no_move() -> void:
	print("\n== defect 3: SPACE/WASD suppressed while typing ==")
	var host := Node3D.new()
	get_root().add_child(host)
	var player: CharacterBody3D = FpsControllerScript.new()
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	col.shape = cap
	col.position = Vector3(0, 0.9, 0)
	player.add_child(col)
	host.add_child(player)
	player.global_position = Vector3(0, 5, 0)
	var cl := CanvasLayer.new()
	host.add_child(cl)
	var le := LineEdit.new()
	cl.add_child(le)
	le.grab_focus()
	await process_frame
	_check("text_input_active TRUE with a focused LineEdit", InputGate.text_input_active(get_root()))
	var start := player.global_position
	for i in 30:
		await physics_frame
	var horiz := Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
	_check("no horizontal movement while a text field is focused (delta=%.3f)" % horiz, horiz < 0.01)
	_check("controller velocity X/Z zeroed while typing", absf(player.velocity.x) < 0.001 and absf(player.velocity.z) < 0.001)
	host.queue_free()
	await process_frame

# ---- 4: sandbox inventory drag moves an item ------------------------------------------------------
func _t4_inventory_drag() -> void:
	print("\n== defect 4: sandbox inventory drag works ==")
	var sb: Node = SandboxScene.instantiate()
	get_root().add_child(sb)
	for i in 4:
		await process_frame
	sb.call("_toggle_inventory")
	await process_frame
	_check("inventory opens on toggle", bool(sb.get("_inv_open")))
	sb.call("_set_hotbar_slot", 0, 5)
	var hotbar_after = sb.get("hotbar") as Array
	_check("drag drop set hotbar slot 0 to palette #5", int(hotbar_after[0]) == 5)
	sb.call("_set_hotbar_slot", 1, 7)
	sb.call("_swap_hotbar_slots", 0, 1)
	_check("hotbar->hotbar swap exchanged slots", int((sb.get("hotbar") as Array)[0]) == 7 and int((sb.get("hotbar") as Array)[1]) == 5)
	sb.queue_free()
	await process_frame

# ---- 5: ESC in inventory closes it, scene unchanged -----------------------------------------------
func _t5_esc_inventory_stays() -> void:
	print("\n== defect 5: ESC closes inventory, does not leave ==")
	var sb: Node = SandboxScene.instantiate()
	get_root().add_child(sb)
	for i in 4:
		await process_frame
	current_scene = sb   # mirror the real game: the sandbox is tree.current_scene (change_scene_to_file)
	sb.call("_toggle_inventory")
	await process_frame
	_check("wants_esc() TRUE while inventory open", sb.has_method("wants_esc") and bool(sb.call("wants_esc")))
	_check("scene_holds_esc TRUE while inventory open (current_scene wants ESC)", InputGate.scene_holds_esc(self))
	sb.call("_on_escape")
	await process_frame
	_check("ESC closed the inventory", not bool(sb.get("_inv_open")))
	_check("wants_esc() FALSE after closing", not bool(sb.call("wants_esc")))
	current_scene = null
	sb.queue_free()
	await process_frame

# ---- 6: kaykit dungeon is walkable ----------------------------------------------------------------
func _t6_kaykit_can_move() -> void:
	print("\n== defect 6: kaykit dungeon movement ==")
	var ex: Node = ExploreScript.new()
	get_root().add_child(ex)
	ex.set("_slug", "kaykit_dungeon")
	ex.call("_enter_scene", "kaykit_dungeon")
	for i in 30:
		await physics_frame
	var player = ex.get_node_or_null("Player")
	_check("kaykit built a Player", player != null)
	if player == null:
		ex.queue_free()
		await process_frame
		return
	var start = player.global_position
	for i in 40:
		player.velocity.x = -3.0
		player.velocity.z = -3.0
		if not player.is_on_floor():
			player.velocity.y -= 14.0 * (1.0 / 60.0)
		player.move_and_slide()
		await physics_frame
	var moved = start.distance_to(player.global_position)
	_check("player MOVED in the kaykit dungeon (delta=%.3f m, was 0.0 before fix)" % moved, moved > 0.5)
	print("   spawn=", start, " end=", player.global_position)
	ex.queue_free()
	await process_frame
