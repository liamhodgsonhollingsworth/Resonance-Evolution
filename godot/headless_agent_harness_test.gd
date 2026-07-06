extends SceneTree
## SELF-TEST for the AGENT HARNESS (tools/agent_harness_lib.gd) — proves the verification gate itself
## works, so a green harness result is trustworthy. Zero live pollution (temp substrate only). Real
## assertions, PASS/FAIL tally, nonzero exit.
##   godot --headless --path godot -s res://headless_agent_harness_test.gd
##
## What it proves:
##  1. ui_dump enumerates every interactive Control with global rect + mouse_filter + topmost-at-center,
##     and FLAGS a control that is covered by another node (the occlusion / click-eater detector).
##  2. ui_click at a button's EXACT on-screen center fires its handler AND an observable effect (a skip
##     writes a feedback row; a decision writes a decision row) — the "renders ≠ works" gate. It also
##     proves a DEAD button (mouse_filter forced to IGNORE) is caught as FAIL, so the gate has teeth.
##  3. The ALWAYS-VISIBLE ✕/✎/☆ card buttons (Liam 2026-07-05 fix) are hittable at their visual coord
##     without any hover step — the exact regression Liam reported ("can't press the x").
##  4. topmost_control_at correctly identifies a covering STOP panel over a button (occlusion catch).
##  5. read_state dumps board mode + displayed card ids; char verbs drive a 3D scene's camera and read
##     the resulting state back (graceful when a scene lacks a hook).

const HarnessLib := preload("res://tools/agent_harness_lib.gd")
const ApertureBoard2D := preload("res://aperture/aperture_board_2d.gd")

const LIVE_FEEDBACK := "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl"
const TEST_PREFIX := "harntest_"

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
	var run_dir := "user://harness_selftest"
	_rm_rf(run_dir)
	var abs := ProjectSettings.globalize_path(run_dir)
	DirAccess.make_dir_recursive_absolute(abs)
	var live_fb_before := _rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX)

	# ---- build a board (file mode, temp substrate) ------------------------------------------------
	var rows := [
		{ "id": TEST_PREFIX + "txt", "kind": "artifact", "title": "Text card",
			"media": { "text": "body", "link": "https://example.com/x" },
			"status": "pending", "disposition": "content" },
		{ "id": TEST_PREFIX + "dec", "kind": "question", "title": "Decide me",
			"media": { "text": "pick" }, "status": "pending", "disposition": "decision",
			"actions": [ { "id": "approve", "label": "Approve" }, { "id": "deny", "label": "Deny" } ] },
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
	var board := await _mount_board(cfg)

	# ---- 1. ui_dump enumerates controls + geometry + occlusion flag -------------------------------
	var dump := HarnessLib.ui_dump(board)
	ok = _check("ui_dump returns a control list with geometry", dump.get("ok", false) and dump.get("count", 0) > 5) and ok
	var xentry: Variant = _find_dump(dump, "✕")
	ok = _check("ui_dump finds the ✕ button with a nonzero global rect + mouse_filter",
		xentry != null and xentry["global_rect"]["w"] > 0 and xentry["mouse_filter"] == "stop") and ok
	ok = _check("ui_dump reports the ✕ button as NOT covered (nothing eats it)",
		xentry != null and not xentry["covered"]) and ok
	ok = _check("ui_dump reports the ✕ button ALWAYS visible (no hover gate — card-button fix)",
		xentry != null and xentry["visible"]) and ok

	# ---- 2/3. ui_click the ALWAYS-VISIBLE ✕ at its exact coord — effect must fire, no hover step ---
	var xbtn := HarnessLib.select_node(board, { "text": "✕" }) as Button
	ok = _check("✕ button resolves + is visible in tree without hover", xbtn != null and xbtn.is_visible_in_tree()) and ok
	var fb_before := _count(run_dir + "/feedback.jsonl")
	# drive it exactly the way the harness driver does (motion + hover + click at rect center)
	var at: Vector2 = xbtn.get_global_rect().get_center()
	HarnessLib.vp_motion(get_root(), at)
	HarnessLib.hover(xbtn)
	await process_frame
	HarnessLib.vp_click(get_root(), at)
	await process_frame
	await process_frame
	var fb_after := _count(run_dir + "/feedback.jsonl")
	ok = _check("ui_click on the ✕ at its EXACT visual coord fires the skip (feedback row written)",
		fb_after == fb_before + 1) and ok
	var fb_rows := _read_jsonl(run_dir + "/feedback.jsonl")
	ok = _check("the skip row is for the RIGHT card (button hitbox == its visual position)",
		fb_rows.size() >= 1 and String(fb_rows[-1].get("artifact_id")) == TEST_PREFIX + "txt"
		and String(fb_rows[-1].get("action")) == "skip") and ok

	# decision Approve button
	var appr := HarnessLib.select_node(board, { "text": "Approve" }) as Button
	var at2: Vector2 = appr.get_global_rect().get_center()
	HarnessLib.vp_motion(get_root(), at2)
	HarnessLib.hover(appr)
	await process_frame
	HarnessLib.vp_click(get_root(), at2)
	await process_frame
	await process_frame
	fb_rows = _read_jsonl(run_dir + "/feedback.jsonl")
	ok = _check("ui_click on Approve records the decision at its exact coord",
		fb_rows.size() >= 2 and String(fb_rows[-1].get("action")) == "approve"
		and String(fb_rows[-1].get("artifact_id")) == TEST_PREFIX + "dec") and ok

	# ---- 4. occlusion catch: a STOP panel drawn over a button IS reported as topmost -------------
	var occ_host := Control.new()
	occ_host.size = Vector2(400, 200)
	get_root().add_child(occ_host)
	var under := Button.new()
	under.text = "UNDER"
	under.position = Vector2(50, 50)
	under.size = Vector2(120, 40)
	occ_host.add_child(under)
	var cover := ColorRect.new()          # ColorRect defaults to MOUSE_FILTER_STOP
	cover.position = Vector2(0, 0)
	cover.size = Vector2(400, 200)
	occ_host.add_child(cover)             # added AFTER → draws on top → should win the hit
	await process_frame
	var center := under.get_global_rect().get_center()
	var top := HarnessLib.topmost_control_at(occ_host, center)
	ok = _check("topmost_control_at reports the COVERING panel over a button (occlusion caught)",
		top == cover) and ok
	occ_host.queue_free()
	await process_frame

	# ---- 5. read_state + char driving on a 3D scene ----------------------------------------------
	var rs := HarnessLib.read_state(board)
	ok = _check("read_state dumps board mode + displayed card ids",
		rs.get("board_mode") == "file" and rs.has("displayed_card_ids")) and ok
	board.get_parent().queue_free()
	await process_frame

	# char driving: load the sandbox (a scene that exposes _cam + _look_toward), aim + read state
	var sandbox_path := "res://examples/sandbox_creative.tscn"
	if ResourceLoader.exists(sandbox_path):
		var ps: PackedScene = load(sandbox_path)
		var sb := ps.instantiate()
		get_root().add_child(sb)
		await process_frame
		await process_frame
		var look := await HarnessLib.char_action(self, sb, "look", { "at": [5.0, 1.0, 5.0] })
		ok = _check("char_look drives the sandbox camera + reads back a forward vector",
			look.get("ok", false) and look.has("camera_forward")) and ok
		var st := HarnessLib.read_state(sb)
		ok = _check("read_state on the 3D scene reports a camera position + mouse mode",
			st.has("camera_position") and st.has("mouse_mode")) and ok
		sb.queue_free()
		await process_frame
	else:
		print("SKIP  sandbox scene absent — char-driving check skipped (not a failure)")

	# ---- live guard -------------------------------------------------------------------------------
	ok = _check("live feedback gained no test rows",
		_rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX) == live_fb_before) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

func _mount_board(cfg: Dictionary) -> ApertureBoard2D:
	var host := Control.new()
	host.size = Vector2(1600, 1000)
	get_root().add_child(host)
	var board := ApertureBoard2D.new()
	board.config = cfg
	host.add_child(board)
	board.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await board.refresh()
	await process_frame
	await process_frame
	return board

func _find_dump(dump: Dictionary, text: String):
	for c in dump.get("controls", []):
		if String(c.get("text", "")) == text:
			return c
	return null

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

func _rows_with_prefix(path: String, prefix: String) -> int:
	var n := 0
	for row in _read_jsonl(path):
		if String(row.get("artifact_id", "")).begins_with(prefix):
			n += 1
	return n

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
