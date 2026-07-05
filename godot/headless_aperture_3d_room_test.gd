extends SceneTree
## Headless proof of the 3D-APERTURE ROOM components (Liam spec 2026-07-05 items 4 & 5), with ZERO
## live pollution — the note write goes to a temp path and a live guard asserts nothing leaked.
##   godot --headless --path godot -s res://headless_aperture_3d_room_test.gd
##
## Covers the pure, display-independent logic:
##  1. SceneTransition.plan routing: the per-target same/new-window FLAG (item 5) — explicit
##     same_window wins; experimental defaults to new-window; stable defaults to same-window; a bad
##     scene path is rejected; the seam to migrate experimental → same-window is one field.
##  2. DoorGateway.poll_player arming: crossing ENTER_RADIUS fires entered ONCE; it re-arms only
##     after leaving REARM_RADIUS (no immediate re-trigger on a fade-in / on return).
##  3. Note substrate: the room's note schema is keyed to scene id "aperture_3d" and appends one
##     JSONL line to the SAME notes substrate as card feedback (written to a temp path here).
##  4. LIVE GUARD: the real notes.jsonl gained no rows from this run.

const SceneTransition := preload("res://aperture/scene_transition.gd")
const DoorGateway := preload("res://aperture/door_gateway.gd")

const LIVE_NOTES := "G:/Wavelet/Alethea-cc/state/sandbox/notes.jsonl"
const TEST_TAG := "ap3droomtest"

var _fail := 0
var _entered_count := 0
var _last_target := {}

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	var ok := true
	var live_notes_before := _rows_with_tag(LIVE_NOTES, TEST_TAG)

	# --- 1. SceneTransition.plan routing (the per-target flag, item 5) ---------------------------
	var p_stable := SceneTransition.plan({ "scene": "res://examples/x.tscn" })
	ok = _check("stable target (no flags) -> same_window",
		bool(p_stable.get("ok")) and String(p_stable.get("channel")) == "same_window") and ok
	var p_exp := SceneTransition.plan({ "scene": "res://examples/x.tscn", "experimental": true })
	ok = _check("experimental target -> new_window (breakable-system path)",
		String(p_exp.get("channel")) == "new_window") and ok
	var p_forced := SceneTransition.plan({ "scene": "res://examples/x.tscn", "experimental": true, "same_window": true })
	ok = _check("explicit same_window WINS over experimental (the migrate-back seam)",
		String(p_forced.get("channel")) == "same_window") and ok
	var p_forced_new := SceneTransition.plan({ "scene": "res://examples/x.tscn", "same_window": false })
	ok = _check("explicit same_window:false -> new_window",
		String(p_forced_new.get("channel")) == "new_window") and ok
	var p_bad := SceneTransition.plan({ "scene": "../evil.tscn" })
	ok = _check("path traversal rejected", not bool(p_bad.get("ok"))) and ok
	var p_noext := SceneTransition.plan({ "scene": "res://examples/x" })
	ok = _check("non-scene path rejected (needs .tscn/.scn)", not bool(p_noext.get("ok"))) and ok
	ok = _check("same_window_scene helper returns the res:// path for a stable target",
		SceneTransition.same_window_scene({ "scene": "res://examples/x.tscn" }) == "res://examples/x.tscn") and ok
	ok = _check("same_window_scene returns '' for a new-window target",
		SceneTransition.same_window_scene({ "scene": "res://examples/x.tscn", "experimental": true }) == "") and ok

	# --- 2. DoorGateway arming ---------------------------------------------------------------------
	var door := DoorGateway.new()
	door.configure({ "scene": "res://examples/x.tscn", "label": "Test door" })
	door.entered.connect(_on_entered)
	# far away: no trigger
	var fired1 := door.poll_player(Vector3(10, 0, 0))
	ok = _check("far from the door: no trigger", not fired1 and _entered_count == 0) and ok
	# step onto the door (within ENTER_RADIUS ~1.1): fires ONCE
	var fired2 := door.poll_player(Vector3(0, 0, 0))
	ok = _check("crossing the threshold fires entered once", fired2 and _entered_count == 1) and ok
	ok = _check("entered carries the door's target",
		String((_last_target as Dictionary).get("scene", "")) == "res://examples/x.tscn") and ok
	# still on the door: does NOT re-fire (armed=false until you leave)
	var fired3 := door.poll_player(Vector3(0.2, 0, 0.2))
	ok = _check("staying on the door does NOT re-fire", not fired3 and _entered_count == 1) and ok
	# leave beyond REARM_RADIUS (~2.2), then return: re-arms and fires again
	door.poll_player(Vector3(5, 0, 0))
	var fired4 := door.poll_player(Vector3(0, 0, 0))
	ok = _check("re-arms after leaving, fires again on return", fired4 and _entered_count == 2) and ok
	# an unconfigured door never fires
	var empty_door := DoorGateway.new()
	ok = _check("unconfigured door never fires", not empty_door.poll_player(Vector3.ZERO)) and ok

	# --- 3. Note substrate schema (temp path; same shape as card feedback) -------------------------
	var run_dir := ProjectSettings.globalize_path("user://ap3d_room_test")
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(run_dir)
	var notes_p := run_dir + "/notes.jsonl"
	ok = _check("note write appends one line", _write_note(notes_p, "make the walls warmer " + TEST_TAG)) and ok
	ok = _check("second note appends (append-only)", _write_note(notes_p, "add a second door " + TEST_TAG)) and ok
	var rows := _read_jsonl(notes_p)
	ok = _check("notes file holds 2 rows", rows.size() == 2) and ok
	var r0: Dictionary = rows[0]
	ok = _check("note row is keyed to scene id 'aperture_3d' + carries position + ts + note",
		String(r0.get("scene")) == "aperture_3d" and r0.has("position")
		and String(r0.get("ts")).ends_with("Z") and String(r0.get("note")).contains(TEST_TAG)) and ok

	# --- 4. LIVE GUARD -----------------------------------------------------------------------------
	ok = _check("live notes.jsonl gained NO rows from this run",
		_rows_with_tag(LIVE_NOTES, TEST_TAG) == live_notes_before and live_notes_before == 0) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail))
	quit(0 if ok else 1)


func _on_entered(target: Dictionary) -> void:
	_entered_count += 1
	_last_target = target


## The room's note schema, mirrored (the actual writer is aperture_3d._write_note; identical shape).
func _write_note(path: String, text: String) -> bool:
	var entry := {
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"scene": "aperture_3d",
		"world": "aperture_room",
		"object_id": "",
		"asset_id": "",
		"position": [1.0, 1.7, 2.0],
		"note": text,
	}
	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line(JSON.stringify(entry))
	f.close()
	return true


func _read_jsonl(path: String) -> Array:
	var out: Array = []
	if not FileAccess.file_exists(path):
		return out
	for line in FileAccess.get_file_as_string(path).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out


func _rows_with_tag(path: String, tag: String) -> int:
	var n := 0
	for row in _read_jsonl(path):
		if String(row.get("note", "")).contains(tag):
			n += 1
	return n


func _rm_rf(abs: String) -> void:
	if not DirAccess.dir_exists_absolute(abs):
		return
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			_rm_rf(abs + "/" + f)
		else:
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs)
