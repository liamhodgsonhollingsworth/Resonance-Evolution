extends SceneTree
## Headless verification of the GLOBAL F1 note affordance (autoload/gizmo_note.gd), WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_gizmo_note_test.gd
##
## Proves Liam's ask (2026-07-05: "press f1 anywhere and write a note for gizmo to review") holds at the
## data layer, from ANY scene: the GizmoNote autoload singleton exists globally, and its write_note()
## appends a correctly-schemaed row (ts + kind:"gizmo_note" + scene id + scene_file + note) to a notes
## file. We test against a TEMP path (#046-safe: no touching the real store) via both an explicit
## path_override AND the GIZMO_NOTES_PATH env override, so the write path is exercised two ways.
##
## Asserts:
##   (1) the GizmoNote autoload singleton is present globally (available in every scene),
##   (2) write_note() with an explicit path_override returns true and creates the file,
##   (3) the written row is valid JSON with the exact schema (kind:"gizmo_note", ts, scene, scene_file, note),
##   (4) scene id detection: when a scene with a SCENE_ID const is current, the row is keyed to it,
##   (5) appends are additive (a second write_note yields TWO lines, never a rewrite),
##   (6) the GIZMO_NOTES_PATH env override routes writes to the temp store (path-resolution path).

func _initialize() -> void:
	var ok := true

	# (1) the autoload singleton exists globally.
	var gn = root.get_node_or_null("GizmoNote")
	ok = _check("GizmoNote autoload singleton is present globally", gn != null) and ok
	if gn == null:
		_finish(false); return
	ok = _check("GizmoNote exposes write_note()", gn.has_method("write_note")) and ok

	# temp store (user:// is a real temp dir under --headless; #046-safe, never the real notes.jsonl)
	var abs := ProjectSettings.globalize_path("user://headless_gizmo_note_test.jsonl")
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)

	# (2) write_note with an explicit path_override.
	var wrote: bool = gn.write_note("headless global-f1 note one", abs)
	ok = _check("write_note(path_override) returns true", wrote) and ok
	ok = _check("notes file was created", FileAccess.file_exists(abs)) and ok

	# (3) schema check on the row.
	var row = _last_json_line(abs)
	ok = _check("row is a dictionary", typeof(row) == TYPE_DICTIONARY) and ok
	ok = _check("row kind == 'gizmo_note'", String(row.get("kind", "")) == "gizmo_note") and ok
	ok = _check("row has an ISO-8601-UTC ts ending in Z", String(row.get("ts", "")).ends_with("Z") and String(row.get("ts", "")).length() >= 20) and ok
	ok = _check("row carries the note text verbatim", String(row.get("note", "")) == "headless global-f1 note one") and ok
	ok = _check("row carries a 'scene' id key", row.has("scene")) and ok
	ok = _check("row carries a 'scene_file' key", row.has("scene_file")) and ok

	# (4) scene id detection: make a scene root exposing SCENE_ID current, then write again.
	var scene_root := Node.new()
	scene_root.set_script(_ScenedRoot)
	scene_root.name = "FakeScene"
	root.add_child(scene_root)
	current_scene = scene_root
	await process_frame
	var wrote2: bool = gn.write_note("note from a fake scene", abs)
	ok = _check("write_note returns true with a current scene set", wrote2) and ok
	var row2 = _last_json_line(abs)
	ok = _check("row is keyed to the current scene's SCENE_ID const", String(row2.get("scene", "")) == "fake_test_scene") and ok

	# (5) appends are additive (never a rewrite): two writes went to `abs` (steps 2 + 4) -> two lines.
	var lines := _count_lines(abs)
	ok = _check("appends are additive (2 writes to abs -> 2 lines)", lines == 2) and ok

	# (6) GIZMO_NOTES_PATH env override routes writes (path-resolution path).
	var env_abs := ProjectSettings.globalize_path("user://headless_gizmo_note_env.jsonl")
	if FileAccess.file_exists(env_abs):
		DirAccess.remove_absolute(env_abs)
	OS.set_environment("GIZMO_NOTES_PATH", env_abs)
	var wrote3: bool = gn.write_note("note via env override")   # no path_override -> resolver reads env
	ok = _check("write_note (no override) returns true with GIZMO_NOTES_PATH set", wrote3) and ok
	ok = _check("env-override file was written", FileAccess.file_exists(env_abs)) and ok
	var row3 = _last_json_line(env_abs)
	ok = _check("env-routed row carries the note", String(row3.get("note", "")) == "note via env override") and ok
	OS.set_environment("GIZMO_NOTES_PATH", "")

	# cleanup
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)
	if FileAccess.file_exists(env_abs):
		DirAccess.remove_absolute(env_abs)

	_finish(ok)


# A tiny scene root that exposes a SCENE_ID const, to exercise scene-id detection.
const _ScenedRoot := preload("res://headless_gizmo_note_scene.gd")


func _last_json_line(abs: String):
	if not FileAccess.file_exists(abs):
		return null
	var txt := FileAccess.get_file_as_string(abs).strip_edges()
	var lines := txt.split("\n", false)
	if lines.is_empty():
		return null
	return JSON.parse_string(String(lines[lines.size() - 1]))


func _count_lines(abs: String) -> int:
	if not FileAccess.file_exists(abs):
		return 0
	var txt := FileAccess.get_file_as_string(abs).strip_edges()
	if txt == "":
		return 0
	return txt.split("\n", false).size()


func _finish(ok: bool) -> void:
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
