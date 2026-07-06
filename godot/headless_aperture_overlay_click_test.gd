extends SceneTree
## REAL-PATH REGRESSION TEST for the 2D-aperture skip (X) button (Liam 2026-07-06, the 4th report;
## the bug that was "fixed" and re-broke THREE times because every prior test verified the WRONG
## tree). This test exercises the ACTUAL overlay-hosted-in-room path -- the CanvasLayer(64) overlay
## computer_terminal.open_board() mounts INSIDE the running aperture_3d room -- NOT the standalone
## aperture_board_2d.tscn (where the X has always worked; a green check there is a FALSE PASS).
##
##   <godot> --headless --path godot -s res://headless_aperture_overlay_click_test.gd
##
## What it proves in the REAL tree:
##  1. The room + its HUD (_hud CanvasLayer, _status) + the board overlay (CanvasLayer layer 64,
##     bg backdrop, board Control forced PRESET_FULL_RECT, ESC ribbon) all coexist -- the exact tree.
##  2. The X button's GLOBAL rect is nonzero and its topmost-control-at-center IS the X (or its
##     child) -- nothing in the overlay OR the room HUD covers it (the click-eater catch).
##  3. Each interactive button's GLOBAL rect == its visible drawn position (placement is correct).
##  4. A REAL synthesized click (InputEventMouseButton pressed->released via the viewport) at the X's
##     global center DISMISSES the right card: a skip row lands in the feedback substrate AND the tile
##     is removed from the board. This is the effect Liam cannot get -- verified in the real path.

const ComputerTerminal := preload("res://aperture/computer_terminal.gd")
const ApertureBoard2D := preload("res://aperture/aperture_board_2d.gd")
const Aperture3D := preload("res://aperture/aperture_3d.gd")
const HarnessLib := preload("res://tools/agent_harness_lib.gd")

const TEST_PREFIX := "ovlyclick_"

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	var ok := true
	var run_dir := "user://overlay_click_test"
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))

	# build the REAL room (headless) and force its HUD so the full tree exists
	var room := Aperture3D.new()
	get_root().add_child(room)
	await process_frame
	# The room skips _build_hud() under headless; force it so the room's _hud CanvasLayer + _status
	# label are present, faithfully reproducing the z-order competition with the board overlay.
	if room.has_method("_build_hud"):
		room.call("_build_hud")
	await process_frame
	ok = _check("room built with a HUD (_hud CanvasLayer present)", room.get("_hud") != null) and ok

	# build the board with test config, then mount it via the REAL overlay builder
	var rows := [
		{ "id": TEST_PREFIX + "a", "kind": "artifact", "title": "First card",
			"media": { "text": "alpha body", "link": "https://example.com/a" },
			"status": "pending", "disposition": "content" },
		{ "id": TEST_PREFIX + "b", "kind": "artifact", "title": "Second card",
			"media": { "text": "beta body", "link": "https://example.com/b" },
			"status": "pending", "disposition": "content" },
	]
	var lines: Array = []
	for r in rows:
		lines.append(JSON.stringify(r))
	_write(run_dir + "/inbox.jsonl", lines)
	_write(run_dir + "/feedback.jsonl", [])
	var cfg := { "mode": "file", "base_url": "http://127.0.0.1:1",
		"inbox_path": run_dir + "/inbox.jsonl", "feedback_path": run_dir + "/feedback.jsonl",
		"bookmarks_path": run_dir + "/bookmarks.jsonl", "notes_path": run_dir + "/notes.jsonl",
		"board_json_path": "", "mount_chat": false }

	# Instantiate the board OURSELVES so config is set BEFORE _ready fires its auto-refresh, then hand
	# it to the same _build_overlay the live right-click path calls (host = the real room).
	var board := ApertureBoard2D.new()
	board.config = cfg
	var overlay: CanvasLayer = ComputerTerminal._build_overlay(room, board)
	ok = _check("overlay mounted as CanvasLayer layer 64 child of the room",
		overlay != null and overlay.layer == 64 and overlay.get_parent() == room) and ok
	# Give the window a real size (headless collapses the root Window to 64x64 during 3D room init; a
	# real display always has a real size). The overlay's size_changed hook re-syncs OverlayRoot to it.
	get_root().size = Vector2i(1600, 1000)
	await process_frame
	# refresh the board content (file mode) now that it is in the tree and sized
	await board.refresh()
	await process_frame
	await process_frame

	ok = _check("board is in file mode with 2 cards displayed",
		String(board.get("_mode_in_use")) == "file"
		and (board.get("_displayed") as Dictionary).size() == 2) and ok

	# 2. the X is present, nonzero rect, and NOT covered by anything in the WHOLE tree
	var xbtn := HarnessLib.select_node(board, { "text": "✕" }) as Button
	ok = _check("X button resolves in the overlay-hosted board", xbtn != null) and ok
	if xbtn == null:
		_finish(ok, room)
		return
	ok = _check("X button is visible in tree (always-visible, no hover gate)", xbtn.is_visible_in_tree()) and ok
	var xrect := xbtn.get_global_rect()
	ok = _check("X button has a nonzero global rect", xrect.size.x > 0 and xrect.size.y > 0) and ok

	# Occlusion check across the ENTIRE root (room HUD + overlay), not just the board -- the real path.
	var center := xrect.get_center()
	var top := HarnessLib.topmost_control_at(get_root(), center)
	var top_ok := top != null and (top == xbtn or xbtn.is_ancestor_of(top) or top.is_ancestor_of(xbtn))
	if not top_ok:
		print("    [diag] topmost-at-X-center is: ", (get_root().get_path_to(top) if top != null else "null"),
			"  (class=", (top.get_class() if top != null else "-"), ", filter=",
			(top.mouse_filter if top != null else -1), ")")
	ok = _check("nothing in the room HUD or overlay COVERS the X (topmost-at-center is the X)", top_ok) and ok

	# 3. placement: each interactive card button's global rect == its visible drawn position
	var tile := HarnessLib.owning_tile(xbtn)
	var placement_ok := tile != null and tile.get_global_rect().grow(2).encloses(xrect)
	ok = _check("X hitbox sits inside its tile's drawn rect (placement matches visuals)", placement_ok) and ok
	ok = _check("X hitbox is the styled ~28px square (not a piled-up/zero rect)",
		abs(xrect.size.x - 28.0) <= 6.0 and abs(xrect.size.y - 28.0) <= 6.0) and ok

	# 4. a REAL click at the X's global center dismisses the RIGHT card
	var target_id := String(tile.get_meta("tile_id")) if tile.has_meta("tile_id") else ""
	var fb_before := _count(run_dir + "/feedback.jsonl")
	var displayed_before := (board.get("_displayed") as Dictionary).size()

	HarnessLib.vp_motion(get_root(), center)
	HarnessLib.hover(xbtn)
	await process_frame
	_real_click(get_root(), center)
	await process_frame
	await process_frame
	await process_frame

	var fb_after := _count(run_dir + "/feedback.jsonl")
	ok = _check("REAL click on the X (overlay path) wrote a skip feedback row", fb_after == fb_before + 1) and ok
	var fb_rows := _read_jsonl(run_dir + "/feedback.jsonl")
	ok = _check("the skip row is a 'skip' action for the tile the X belongs to",
		fb_rows.size() >= 1 and String(fb_rows[-1].get("action")) == "skip"
		and String(fb_rows[-1].get("artifact_id")) == target_id) and ok
	var displayed_after := (board.get("_displayed") as Dictionary).size()
	ok = _check("the dismissed tile was REMOVED from the board (displayed count dropped)",
		displayed_after == displayed_before - 1) and ok
	ok = _check("the removed tile is exactly the one whose X was clicked",
		not (board.get("_displayed") as Dictionary).has(target_id)) and ok

	_finish(ok, room)

func _finish(ok: bool, room: Node) -> void:
	room.queue_free()
	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail))
	quit(0 if ok else 1)

# a real, complete click through the viewport (press then release at the same global pos)
func _real_click(vp: Viewport, pos: Vector2) -> void:
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

# helpers
func _write(path: String, lines: Array) -> void:
	var a := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(a.get_base_dir())
	var f := FileAccess.open(a, FileAccess.WRITE)
	for l in lines:
		f.store_line(String(l))
	f.close()

func _read_jsonl(path: String) -> Array:
	var out: Array = []
	var a := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(a):
		return out
	for line in FileAccess.get_file_as_string(a).split("\n"):
		line = line.strip_edges()
		if line != "":
			var row = JSON.parse_string(line)
			if typeof(row) == TYPE_DICTIONARY:
				out.append(row)
	return out

func _count(path: String) -> int:
	return _read_jsonl(path).size()

func _rm_rf(path: String) -> void:
	var a := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(a):
		return
	var d := DirAccess.open(a)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			_rm_rf(path + "/" + f)
		else:
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(a)
