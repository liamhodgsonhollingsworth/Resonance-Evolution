extends SceneTree
## FEEDBACK-LOOP end-to-end proof (Liam 2026-07-05 item 2): "make sure that my responses and feedback
## are actually recorded and used when I open the aperture, including the approve/deny".
##   godot --headless --path godot -s res://headless_feedback_loop_test.gd
##
## Proves all three legs of the loop with zero live pollution (temp substrate):
##   1. RECORD:   a decision made on the Godot board (approve/deny/skip) + a per-card note write a
##                durable row to the feedback / notes substrate (the SAME files the web board reads).
##   2. PERSIST:  the rows survive on disk in the byte-compatible schema.
##   3. USE ON REOPEN: mounting a FRESH board over the same substrate reflects the decision — a
##                decided card (approve/deny/skip) is GONE from the reopened board (latest-action-wins
##                hide), and a per-card note round-trips by module_id. This is "feedback used when I
##                open the aperture".
##   4. F1 NOTE:  the GizmoNote autoload's write_note() appends a schema-correct gizmo_note row to the
##                sandbox notes store (the F1 feedback channel) — proven directly against a temp file.

const ApertureBoard2D := preload("res://aperture/aperture_board_2d.gd")
const ApertureInbox := preload("res://aperture/aperture_inbox.gd")
const GizmoNote := preload("res://autoload/gizmo_note.gd")

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
	var run_dir := "user://feedback_loop_test"
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))

	var inbox := run_dir + "/inbox.jsonl"
	var feedback := run_dir + "/feedback.jsonl"
	var notes := run_dir + "/notes.jsonl"
	_write(inbox, [
		JSON.stringify({ "id": "fl_content", "kind": "artifact", "title": "A content card",
			"media": { "text": "body", "link": "https://example.com/x" },
			"status": "pending", "disposition": "content" }),
		JSON.stringify({ "id": "fl_review", "kind": "question", "title": "A review card",
			"media": { "text": "approve or deny" }, "status": "pending", "disposition": "decision",
			"actions": [ { "id": "approve", "label": "Approve" }, { "id": "deny", "label": "Deny" } ] }),
	])
	_write(feedback, [])
	_write(notes, [])
	var cfg := { "mode": "file", "base_url": "http://127.0.0.1:1",
		"inbox_path": inbox, "feedback_path": feedback, "bookmarks_path": run_dir + "/bookmarks.jsonl",
		"notes_path": notes, "board_json_path": "", "mount_chat": false }

	# ---- 1+2. RECORD a decision + a note on the FIRST board mount --------------------------------
	var board := await _mount(cfg)
	ok = _check("first mount shows the review card in the notifications banner",
		board._notif_row.visible and board._notif_row.get_child_count() == 1) and ok
	ok = _check("first mount shows the content card in the grid", board._displayed.has("fl_content")) and ok
	# approve the review card programmatically (the exact call the Approve button makes)
	var review_tile: Control = board._notif_row.get_child(0)
	board._decide({ "id": "fl_review" }, "approve", review_tile, "looks good to me")
	# write a per-card note on the content card (the exact call the ✎ Send does)
	board._submit_card_note({ "id": "fl_content", "source": "inbox", "title": "A content card" },
		_make_lineedit("please make the sky more painterly"), Label.new())
	await process_frame

	var fb := _read_jsonl(feedback)
	ok = _check("approve decision wrote ONE durable feedback row (byte-compatible schema)",
		fb.size() == 1 and String(fb[0].get("artifact_id")) == "fl_review"
		and String(fb[0].get("action")) == "approve" and String(fb[0].get("by")) == "liam"
		and String(fb[0].get("decided_at")).ends_with("Z")) and ok
	ok = _check("the approve comment rode the feedback row (approve/deny reason persists)",
		fb.size() == 1 and String(fb[0].get("comment", "")) == "looks good to me") and ok
	var nrows := _read_jsonl(notes)
	ok = _check("per-card note wrote ONE row keyed on the FULL web DOM tile id",
		nrows.size() == 1 and String(nrows[0].get("module_id")) == "tile_artifact_fl_content"
		and String(nrows[0].get("text")) == "please make the sky more painterly") and ok
	board.get_parent().queue_free()
	await process_frame

	# ---- 3. USE ON REOPEN: a FRESH board over the same substrate reflects the decision -----------
	var board2 := await _mount(cfg)
	ok = _check("REOPEN: the approved review card is GONE (decision reflected, latest-action-wins hide)",
		not board2._displayed.has("fl_review") and board2._notif_row.get_child_count() == 0) and ok
	ok = _check("REOPEN: the un-decided content card still shows (only decided cards leave)",
		board2._displayed.has("fl_content")) and ok
	# the hide set the reopened board reads is exactly the one the web board reads
	var hidden := ApertureInbox.hidden_ids(feedback)
	ok = _check("the shared hidden-set (what the WEB board also reads) contains the approved card",
		hidden.has("fl_review")) and ok
	board2.get_parent().queue_free()
	await process_frame

	# a deny then a later action still hides; skip also hides — the loop treats all decisions the same
	_write(run_dir + "/fb2.jsonl", [
		JSON.stringify({ "artifact_id": "d1", "action": "deny", "decided_at": "2026-07-05T00:00:00Z", "by": "liam" }),
		JSON.stringify({ "artifact_id": "d2", "action": "skip", "decided_at": "2026-07-05T00:00:01Z", "by": "liam" }),
		JSON.stringify({ "artifact_id": "d2", "action": "unskip", "decided_at": "2026-07-05T00:00:02Z", "by": "liam" }),
	])
	var h2 := ApertureInbox.hidden_ids(run_dir + "/fb2.jsonl")
	ok = _check("deny hides; skip-then-unskip un-hides (latest-action-wins for approve/deny/skip alike)",
		h2.has("d1") and not h2.has("d2")) and ok

	# ---- 4. F1 GizmoNote write path (the sandbox feedback channel) -------------------------------
	var gn := GizmoNote.new()
	get_root().add_child(gn)
	await process_frame
	var f1_path := ProjectSettings.globalize_path(run_dir + "/sandbox_notes.jsonl")
	var wrote := gn.write_note("space still jumps while typing", f1_path)
	ok = _check("F1 GizmoNote.write_note appends a note to the sandbox feedback channel", wrote) and ok
	var f1_rows := _read_jsonl(run_dir + "/sandbox_notes.jsonl")
	ok = _check("the F1 note row is schema-correct {ts,kind:gizmo_note,scene,scene_file,note}",
		f1_rows.size() == 1 and String(f1_rows[0].get("kind")) == "gizmo_note"
		and String(f1_rows[0].get("note")) == "space still jumps while typing"
		and f1_rows[0].has("ts") and f1_rows[0].has("scene")) and ok
	gn.queue_free()

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------

func _mount(cfg: Dictionary) -> ApertureBoard2D:
	var host := Control.new()
	host.size = Vector2(1600, 1000)
	get_root().add_child(host)
	var b := ApertureBoard2D.new()
	b.config = cfg
	host.add_child(b)
	b.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await b.refresh()
	await process_frame
	await process_frame
	return b

func _make_lineedit(text: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	return e

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
