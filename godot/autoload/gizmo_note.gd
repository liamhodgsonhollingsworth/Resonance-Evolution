extends CanvasLayer
## GizmoNote — the GLOBAL F1 note affordance (Liam 2026-07-05):
##   "give me the ability to press f1 anywhere and write a note for gizmo to review"
##
## Registered as an AUTOLOAD singleton (see project.godot [autoload] GizmoNote) so it is present in
## EVERY scene the project ever runs, regardless of which scene is the entry point. Before this, F1
## feedback only worked inside three specific scenes (sandbox_creative, explore, aperture_3d) whose own
## _unhandled_input bound F1; those scene-local F1 bindings are removed in favour of THIS single owner
## so there is no double-open (see the report + the edits in those three .gd files).
##
## WHAT IT DOES
##   • F1 (anywhere) toggles a small centered text box. It captures keyboard focus, releases any mouse
##     capture the scene had (restoring it on close), and does NOT let the note keystrokes leak to the
##     scene underneath (we set_input_as_handled so movement/jump keys stay quiet while typing — this
##     directly fixes the "space still jumps while typing" note in notes.jsonl).
##   • Enter / the Save button appends the note; ESC or F1 cancels. A brief "note saved" confirmation shows.
##   • The typed note is APPENDED to Alethea-cc/state/sandbox/notes.jsonl — the SAME substrate every
##     coordinator (Gizmo / Claude Code) session already reads for scene feedback. The row matches the
##     established scene-feedback schema (ts + kind + scene id + note) so it is indistinguishable in the
##     data contract from a card note or a per-scene F1 note.
##
## F1 OWNERSHIP (documented choice): this autoload is the SINGLE owner of F1 project-wide. It handles F1
## in _input() (which runs before any scene's _unhandled_input), marks the event handled, and toggles the
## box. The three scenes that previously bound F1 have had that binding removed. aperture_3d additionally
## has an 'F' feedback key that predates F1 — that is a DIFFERENT key, so it is left intact; F still opens
## aperture_3d's own richer position-tagged note there, and F1 opens this global box. No conflict.
##
## SCHEMA (matched to the existing rows in notes.jsonl, additive-only):
##   { "ts": "<ISO-8601 UTC>Z", "kind": "gizmo_note", "scene": "<scene id>", "scene_file": "<res path>",
##     "note": "<text>" }
##   'kind' is "gizmo_note" (a new, self-describing kind alongside "scene_feedback"/"in_scene_feedback");
##   'scene' + 'scene_file' tell Gizmo exactly where the note was left. A coordinator reading the file
##   treats every *_feedback / gizmo_note row the same way — free-text handoff keyed to a scene.

const NOTES_REL := "Alethea-cc/state/sandbox/notes.jsonl"
## Absolute fallback (matches the hardcoded path sandbox_creative.gd / aperture_3d.gd already use).
const DEFAULT_NOTES_ABS := "G:/Wavelet/Alethea-cc/state/sandbox/notes.jsonl"
## Env override so headless tests never touch the real store (mirrors SANDBOX_NOTES_PATH usage).
const NOTES_ENV := "GIZMO_NOTES_PATH"

var _open := false
var _panel: PanelContainer
var _edit: LineEdit
var _title: Label
var _confirm: Label
var _confirm_timer: Timer
## Whether the scene had the mouse captured when we opened, so we can restore it exactly on close.
var _restore_capture := false
var _headless := false


func _ready() -> void:
	# Run even while the game is paused, and sit above scene UI.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128
	_headless = DisplayServer.get_name() == "headless"
	if not _headless:
		_build_overlay()


# -- input: this autoload is the single owner of F1 project-wide --------------------------------------
# _input runs before any scene's _unhandled_input, so binding F1 here makes the global box the sole F1
# handler. We consume the event (set_input_as_handled) so scene handlers never also see F1.
func _input(event: InputEvent) -> void:
	if _headless:
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_F1:
		get_viewport().set_input_as_handled()
		toggle()
		return
	# While the box is open, swallow ESC (cancel) here so the scene's own ESC (which often exits to the
	# aperture room — see the "escape when writing a note ... go back to the aperture" note) never fires.
	if _open and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close(false)
		return


func toggle() -> void:
	if _open:
		close(false)
	else:
		open()


func open() -> void:
	if _headless or _panel == null or _open:
		return
	_open = true
	_restore_capture = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _restore_capture:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_confirm.visible = false
	_title.text = "Note for Gizmo - %s" % _scene_id()
	_edit.text = ""
	_edit.placeholder_text = "write a note for Gizmo to review...  (Enter saves - ESC / F1 cancels)"
	_panel.visible = true
	_edit.grab_focus()


## Close the box. If `saved` is false the note is discarded; the caller does the actual save then closes.
func close(saved: bool) -> void:
	if _panel != null:
		_panel.visible = false
	if _edit != null:
		_edit.text = ""
	_open = false
	if _restore_capture and not _headless:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_restore_capture = false
	if saved:
		_flash_confirm("note saved for Gizmo")


func _on_submit(text: String) -> void:
	var note := text.strip_edges()
	if note == "":
		close(false)
		return
	var ok := write_note(note)
	close(ok)
	if not ok:
		_flash_confirm("NOTE FAILED to write")


# -- persistence: append one row to notes.jsonl, schema-matched to the existing scene-feedback rows ----
## Standalone + path-overridable so headless tests call it directly against a temp store. Returns success.
func write_note(text: String, path_override := "") -> bool:
	var abs := path_override if path_override != "" else _notes_abs_path()
	if abs == "":
		push_warning("[gizmo_note] could not resolve notes path")
		return false
	var dir := abs.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var entry := {
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"kind": "gizmo_note",
		"scene": _scene_id(),
		"scene_file": _scene_file(),
		"note": text,
	}
	var f: FileAccess
	if FileAccess.file_exists(abs):
		f = FileAccess.open(abs, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		push_warning("[gizmo_note] could not open notes file: %s" % abs)
		return false
	f.store_line(JSON.stringify(entry))
	f.close()
	print("[gizmo_note] note appended to %s (scene=%s)" % [abs, _scene_id()])
	return true


## Resolve the notes.jsonl path robustly: env override -> relative to res:// (walk up to the repo root) ->
## the hardcoded absolute fallback. Mirrors explore_scene_demo's candidate walk plus the abs fallback the
## sandbox/aperture scenes use, so this works from any checkout location AND from the shared main checkout.
func _notes_abs_path() -> String:
	var env := OS.get_environment(NOTES_ENV)
	if env != "":
		return env
	var proj := ProjectSettings.globalize_path("res://")
	var candidates := [
		proj.path_join("../../../").simplify_path().path_join(NOTES_REL),   # <repo>/godot -> Wavelet root
		proj.path_join("../").simplify_path().path_join(NOTES_REL),
		proj.path_join("../../").simplify_path().path_join(NOTES_REL),
		proj.path_join(NOTES_REL),
	]
	for c in candidates:
		# Accept a candidate whose parent OR grandparent dir already exists (state/ or Alethea-cc/ present).
		var base := (c as String).get_base_dir()
		if DirAccess.dir_exists_absolute(base) or DirAccess.dir_exists_absolute(base.get_base_dir()):
			return c
	# Nothing resolved from res:// -- fall back to the known absolute store on this host.
	if DirAccess.dir_exists_absolute(DEFAULT_NOTES_ABS.get_base_dir()) \
			or DirAccess.dir_exists_absolute(DEFAULT_NOTES_ABS.get_base_dir().get_base_dir()):
		return DEFAULT_NOTES_ABS
	# Last resort: the first candidate (write_note will mkdir -p it).
	return candidates[0]


# -- scene identity: what Gizmo needs to know WHERE the note was left ---------------------------------
## A stable scene id. Prefer a scene-declared SCENE_ID const if present (sandbox/explore/aperture expose
## one); else derive a slug from the current scene file name; else "unknown".
func _scene_id() -> String:
	var cur := _current_scene()
	if cur != null:
		# Honour an explicit SCENE_ID the scene root may expose (a script const, e.g. sandbox/explore/
		# aperture all declare `const SCENE_ID`). Consts are NOT in get_property_list(), so read the
		# script's constant map; Object.get() also resolves them, used as the direct fallback.
		var scr = cur.get_script()
		if scr != null and scr.has_method("get_script_constant_map"):
			var cmap: Dictionary = scr.get_script_constant_map()
			if cmap.has("SCENE_ID") and String(cmap["SCENE_ID"]) != "":
				return String(cmap["SCENE_ID"])
		var sid = cur.get("SCENE_ID")
		if sid != null and String(sid) != "":
			return String(sid)
	var file := _scene_file()
	if file != "":
		return file.get_file().get_basename()
	return "unknown"


func _scene_file() -> String:
	var cur := _current_scene()
	if cur != null and cur.scene_file_path != "":
		return cur.scene_file_path
	return ""


func _current_scene() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.current_scene


# -- overlay UI (built in code; small + centered + unobtrusive) --------------------------------------
func _build_overlay() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(520, 0)
	_panel.visible = false
	center.add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	_panel.add_child(margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	margin.add_child(inner)

	_title = Label.new()
	_title.text = "Note for Gizmo"
	inner.add_child(_title)

	_edit = LineEdit.new()
	_edit.placeholder_text = "write a note for Gizmo to review...  (Enter saves - ESC / F1 cancels)"
	_edit.custom_minimum_size = Vector2(490, 0)
	_edit.text_submitted.connect(_on_submit)
	inner.add_child(_edit)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	inner.add_child(buttons)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel (Esc)"
	cancel_btn.pressed.connect(func(): close(false))
	buttons.add_child(cancel_btn)

	var save_btn := Button.new()
	save_btn.text = "Save (Enter)"
	save_btn.pressed.connect(func(): _on_submit(_edit.text))
	buttons.add_child(save_btn)

	_confirm = Label.new()
	_confirm.text = ""
	_confirm.visible = false
	inner.add_child(_confirm)

	_confirm_timer = Timer.new()
	_confirm_timer.one_shot = true
	_confirm_timer.wait_time = 1.6
	_confirm_timer.timeout.connect(func(): if _confirm != null: _confirm.visible = false)
	add_child(_confirm_timer)


func _flash_confirm(msg: String) -> void:
	if _confirm == null or _panel == null:
		return
	_confirm.text = msg
	_confirm.visible = true
	# When the panel is hidden (post-save), briefly show the confirmation on its own then hide it.
	var show_solo := not _panel.visible
	if show_solo:
		_panel.visible = true
		_edit.text = ""
	if _confirm_timer != null:
		_confirm_timer.start()
	if show_solo and not _open:
		await _confirm_timer.timeout
		if not _open and _panel != null:
			_panel.visible = false
