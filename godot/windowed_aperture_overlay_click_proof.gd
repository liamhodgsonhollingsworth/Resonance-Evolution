extends SceneTree
## WINDOWED before/after PROOF (real display) for the 2D-aperture skip (X) button in the REAL
## overlay-hosted-in-room path (Liam 2026-07-06). Mounts the aperture_3d room + HUD + the board
## overlay (CanvasLayer 64) exactly as the in-room computer right-click does, screenshots BEFORE,
## synthesizes a REAL click at the X button's VISIBLE global position, screenshots AFTER, and prints
## whether the card was dismissed. Uses a temp file-mode substrate -> zero live pollution.
##
##   <godot> --path godot -s res://windowed_aperture_overlay_click_proof.gd
##   (NOT --headless: this needs a real window to screenshot the pixels Liam sees.)
##
## Outputs: docs/proof_overlay_click_before.png, docs/proof_overlay_click_after.png

const ComputerTerminal := preload("res://aperture/computer_terminal.gd")
const ApertureBoard2D := preload("res://aperture/aperture_board_2d.gd")
const Aperture3D := preload("res://aperture/aperture_3d.gd")
const HarnessLib := preload("res://tools/agent_harness_lib.gd")

const OUT_DIR := "res://docs"
const RUN_DIR := "user://overlay_click_proof"

func _initialize() -> void:
	_run()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("[proof] needs a real display (no --headless). Exit 2.")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RUN_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	get_root().size = Vector2i(1440, 900)

	# real room + forced HUD (the room skips it only under headless; here it builds anyway)
	var room := Aperture3D.new()
	get_root().add_child(room)
	for _i in 6:
		await process_frame

	# test cards -> temp substrate
	var rows := [
		{ "id": "proof_a", "kind": "artifact", "title": "SKIP-ME card (click its X)",
			"media": { "text": "This tile should VANISH when its X is clicked.", "link": "https://example.com/a" },
			"status": "pending", "disposition": "content" },
		{ "id": "proof_b", "kind": "artifact", "title": "Neighbor card (stays)",
			"media": { "text": "This tile should remain after the other is skipped.", "link": "https://example.com/b" },
			"status": "pending", "disposition": "content" },
		{ "id": "proof_c", "kind": "artifact", "title": "Third card (stays)",
			"media": { "text": "Filler so the board reads as a real bento grid.", "link": "https://example.com/c" },
			"status": "pending", "disposition": "content" },
	]
	var lines: Array = []
	for r in rows:
		lines.append(JSON.stringify(r))
	_write(RUN_DIR + "/inbox.jsonl", lines)
	_write(RUN_DIR + "/feedback.jsonl", [])
	var cfg := { "mode": "file", "base_url": "http://127.0.0.1:1",
		"inbox_path": RUN_DIR + "/inbox.jsonl", "feedback_path": RUN_DIR + "/feedback.jsonl",
		"bookmarks_path": RUN_DIR + "/bookmarks.jsonl", "notes_path": RUN_DIR + "/notes.jsonl",
		"board_json_path": "", "mount_chat": false }

	var board := ApertureBoard2D.new()
	board.config = cfg
	ComputerTerminal._build_overlay(room, board)
	get_root().size = Vector2i(1440, 900)   # ensure a real size after room init collapse quirk
	for _i in 4:
		await process_frame
	await board.refresh()
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw

	var displayed_before := (board.get("_displayed") as Dictionary).size()
	print("[proof] displayed cards before: ", displayed_before, "  ids=", (board.get("_displayed") as Dictionary).keys())

	# BEFORE screenshot
	await _shot(OUT_DIR + "/proof_overlay_click_before.png")

	# find the X of the 'proof_a' tile specifically (not just any X)
	var tile := board.find_child("Tile_proof_a", true, false)
	var xbtn: Button = null
	if tile != null:
		var overlay := tile.find_child("TileOverlay", true, false)
		if overlay != null:
			for b in overlay.get_children():
				if b is Button and String((b as Button).text) == "✕":
					xbtn = b
					break
	if xbtn == null:
		print("[proof] FAILED to locate proof_a X button")
		quit(3)
		return
	var center := xbtn.get_global_rect().get_center()
	print("[proof] proof_a X global center = ", center, "  rect=", xbtn.get_global_rect())

	# REAL click at the visible position (motion -> hover -> press -> release)
	HarnessLib.vp_motion(get_root(), center)
	HarnessLib.hover(xbtn)
	await process_frame
	_click(get_root(), center)
	for _i in 8:
		await process_frame
	await RenderingServer.frame_post_draw

	var displayed_after := (board.get("_displayed") as Dictionary).size()
	var gone := not (board.get("_displayed") as Dictionary).has("proof_a")
	print("[proof] displayed cards after: ", displayed_after, "  proof_a removed? ", gone)
	print("[proof] feedback rows written: ", _count(RUN_DIR + "/feedback.jsonl"))

	# AFTER screenshot
	await _shot(OUT_DIR + "/proof_overlay_click_after.png")

	print("[proof] RESULT: ", ("PASS - X dismissed the card in the windowed real path"
		if (gone and displayed_after == displayed_before - 1) else "FAIL - card not dismissed"))
	quit(0)

func _shot(path: String) -> void:
	for _i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	img.save_png(path)
	print("[proof] wrote ", path, "  size=", img.get_size())

func _click(vp: Viewport, pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	vp.push_input(down)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	vp.push_input(up)

func _write(path: String, lines: Array) -> void:
	var a := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(a.get_base_dir())
	var f := FileAccess.open(a, FileAccess.WRITE)
	for l in lines:
		f.store_line(String(l))
	f.close()

func _count(path: String) -> int:
	var a := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(a):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(a).split("\n"):
		if line.strip_edges() != "":
			n += 1
	return n
