class_name ViewpointPicker
extends Node3D
## ViewpointPicker -- a general-purpose, REUSABLE node-based camera-placement tool. Liam, verbatim,
## 2026-07-15 (DISPATCH claim underground-railing-iteration-2026-07-15), the load-bearing deliverable
## of his 4-step underground-scene process-refinement: "using those tools to move around in the
## scene, I will place the perspective of the viewer. It would be ideal if you made a node based
## reusable tool where I could place the perspective of the viewer and then have that screen show
## me, in a portion of the screen or separate window, what that viewpoint looks like (this also
## naturally connects to the aperture view into this scene, since that view would be the same) so
## that I can move around the scene and edit things to tune that particular view to look like the
## image."
##
## NOT scene-specific -- drop this ONE node into ANY scene (`add_child(ViewpointPicker.new())` or
## instance it from a `.tscn`) and it works: a free-fly camera Liam drives directly, a live
## picture-in-picture preview of exactly what that camera sees (a SECOND `Camera3D` inside a
## `SubViewport`, kept transform-synced every frame to this node's own transform -- so the PiP is
## always byte-identical to "what this viewpoint looks like", never a stale snapshot), an optional
## pop-out to a separate OS `Window` (satisfies "in a portion of the screen OR separate window"), and
## a small named-pose save/load store so a chosen viewpoint survives a scene reload and can be
## reused by other tools.
##
## Same-view-as-Aperture composability: the pose store this node reads/writes
## (`_poses_path`, schema below) is DELIBERATELY the SAME shape
## `Alethea-cc/tools/image_evolver/reference_camera_score.CameraPoseRegistry` already persists to
## `camera_poses.json` (name/reference/position/look_at/fov_deg/up/notes) -- a pose Liam places here
## can be copied into that Python-side registry verbatim (same keys, same units: Y-up, meters,
## degrees) and immediately used by `reference_camera_score.py`'s scoring harness, and the SAME
## shape is what "the new aperture... scenery view of the evolving scenes" (Liam, 2026-07-15 15:01Z)
## should read its own live camera pose from -- this node is the ONE place a viewpoint gets placed;
## everything else (Aperture's scenery view, the offline reference-comparison scorer) is a consumer
## of the pose it emits, not a second, competing camera-placement UI (no-auto-generalization: this
## claim builds the node + local save/load; wiring it to a remote websocket transport / the
## `param_channel`/`ws://` adapter so Aperture can read a LIVE pose cross-process is a documented
## follow-up, not built in this pass -- see DISPATCH.md queued items).
##
## Controls (a `_hint_label` in the PiP overlay shows these live):
##   Tab              -- toggle placement mode (captures the mouse for fly-look; scene keeps
##                        rendering normally either way, this only gates INPUT, never visibility).
##   W/A/S/D + Space/Shift -- fly forward/left/back/right/up/down (placement mode only).
##   Mouse (while captured) -- look around.
##   Mouse wheel / [ ]  -- adjust FOV (placement mode only).
##   Enter              -- save current pose (prompts via the on-screen name field).
##   , / .              -- cycle through saved poses (load previous/next).
##   O                  -- toggle the pop-out separate Window.
##
## API (for another node/scene to drive or read this tool programmatically -- the "node based" half
## of "node based reusable tool"):
##   get_pose() -> Dictionary            -- current {"position","look_at","fov_deg","up"} (world
##                                           space, Y-up, meters/degrees -- CameraPoseRegistry shape).
##   set_pose(pose: Dictionary) -> void  -- jump the picker to an explicit pose (position + look_at
##                                           OR position + rotation_euler_deg, either accepted).
##   save_pose(name: String) -> Dictionary          -- persist the CURRENT pose under `name`.
##   load_pose(name: String) -> bool                -- true if `name` was found and applied.
##   list_poses() -> Array[String]
##   preview_texture() -> ViewportTexture           -- for a caller (e.g. a future Aperture panel)
##                                                     that wants to embed the SAME live preview
##                                                     itself instead of this node's own PiP overlay.
##   pose_changed(pose: Dictionary)                 -- signal, emitted whenever the pose changes
##                                                     (moved, loaded, or set programmatically).
##
## schema-version: 1.0.0

signal pose_changed(pose: Dictionary)

@export var move_speed: float = 4.0
@export var boost_multiplier: float = 3.0
@export var look_sensitivity: float = 0.0035
@export var pip_size: Vector2i = Vector2i(400, 260)
@export var start_fov_deg: float = 65.0
@export var poses_path: String = "user://viewpoint_poses.json"
@export var reference_name: String = "underground_halls"  # tags saved poses -- matches
                                                            # CameraPoseRegistry's own "reference" key
@export var build_preview: bool = true  # DQ-0343912a, additive: set false BEFORE add_child() to skip
                                         # the PiP SubViewport + on-screen overlay -- for a headless/
                                         # batch caller that only wants get_pose()/set_pose()/
                                         # pose_changed (e.g. a param_channel-driven capture run,
                                         # where a second live-rendering viewport has been observed to
                                         # stall headless capture, see underground_wave6_proof.gd's
                                         # own --shot comment). Default true keeps every EXISTING
                                         # caller's behaviour byte-for-byte unchanged.

var _preview_viewport: SubViewport
var _preview_camera: Camera3D
var _pip_rect: TextureRect
var _hint_label: Label
var _name_edit: LineEdit
var _pose_list_label: Label
var _popup_window: Window = null

var _placement_active: bool = false
var _yaw: float = 0.0
var _pitch: float = 0.0
var _fov: float = 65.0
var _poses: Dictionary = {}       # name(String) -> pose Dictionary
var _pose_names_cache: Array = []
var _cursor_index: int = -1


func _ready() -> void:
	_fov = start_fov_deg
	var basis_euler := rotation
	_yaw = basis_euler.y
	_pitch = basis_euler.x

	if build_preview:
		_build_preview_viewport()
		_build_overlay()
	_load_all_poses()
	set_process(true)
	set_process_unhandled_input(true)


func _build_preview_viewport() -> void:
	_preview_viewport = SubViewport.new()
	_preview_viewport.size = pip_size
	_preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_preview_viewport.transparent_bg = false
	_preview_viewport.world_3d = get_viewport().world_3d if get_viewport() else null
	add_child(_preview_viewport)

	_preview_camera = Camera3D.new()
	_preview_camera.fov = _fov
	_preview_camera.current = false  # this is a SECONDARY camera, never steals the main viewport
	_preview_viewport.add_child(_preview_camera)


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-float(pip_size.x) - 12.0, 12.0)
	panel.size = Vector2(pip_size)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_pip_rect = TextureRect.new()
	_pip_rect.texture = _preview_viewport.get_texture()
	_pip_rect.custom_minimum_size = Vector2(pip_size)
	_pip_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_pip_rect.stretch_mode = TextureRect.STRETCH_SCALE
	vbox.add_child(_pip_rect)

	_hint_label = Label.new()
	_hint_label.text = ("ViewpointPicker  [Tab] placement mode  [WASD+Space/Shift] fly  "
		+ "[wheel/[ ]] fov  [Enter] save  [,/.] cycle poses  [O] pop-out window")
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_hint_label)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "pose name (Enter to save)"
	_name_edit.text_submitted.connect(func(text: String):
		save_pose(text if text.strip_edges() != "" else ("pose_%d" % Time.get_ticks_msec()))
		_name_edit.text = "")
	vbox.add_child(_name_edit)

	_pose_list_label = Label.new()
	_pose_list_label.text = "poses: (none saved yet)"
	_pose_list_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_pose_list_label)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				_placement_active = not _placement_active
				Input.mouse_mode = (Input.MOUSE_MODE_CAPTURED if _placement_active
					else Input.MOUSE_MODE_VISIBLE)
			KEY_ENTER, KEY_KP_ENTER:
				if _name_edit and _name_edit.has_focus():
					pass  # let the LineEdit's own text_submitted signal handle it
				else:
					var nm := "pose_%d" % Time.get_ticks_msec()
					save_pose(nm)
			KEY_COMMA:
				_cycle_pose(-1)
			KEY_PERIOD:
				_cycle_pose(1)
			KEY_O:
				_toggle_popout_window()
			KEY_BRACKETLEFT:
				_fov = clampf(_fov - 3.0, 10.0, 120.0)
			KEY_BRACKETRIGHT:
				_fov = clampf(_fov + 3.0, 10.0, 120.0)

	if _placement_active and event is InputEventMouseMotion:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)

	if _placement_active and event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_fov = clampf(_fov - 2.0, 10.0, 120.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_fov = clampf(_fov + 2.0, 10.0, 120.0)


func _process(delta: float) -> void:
	if _placement_active:
		var dir := Vector3.ZERO
		if Input.is_physical_key_pressed(KEY_W):
			dir -= transform.basis.z
		if Input.is_physical_key_pressed(KEY_S):
			dir += transform.basis.z
		if Input.is_physical_key_pressed(KEY_A):
			dir -= transform.basis.x
		if Input.is_physical_key_pressed(KEY_D):
			dir += transform.basis.x
		if Input.is_physical_key_pressed(KEY_SPACE):
			dir += Vector3.UP
		if Input.is_physical_key_pressed(KEY_SHIFT):
			dir -= Vector3.UP
		var speed := move_speed
		if Input.is_physical_key_pressed(KEY_CTRL):
			speed *= boost_multiplier
		if dir.length() > 0.0001:
			global_position += dir.normalized() * speed * delta
			emit_signal("pose_changed", get_pose())

	if _preview_camera != null:
		_preview_camera.global_transform = global_transform
		_preview_camera.fov = _fov


## Current pose in `CameraPoseRegistry` shape (world-space, Y-up, meters/degrees).
func get_pose() -> Dictionary:
	var fwd := -global_transform.basis.z
	var pos := global_position
	var look_at := pos + fwd * 10.0
	return {
		"name": "", "reference": reference_name,
		"position": [pos.x, pos.y, pos.z], "look_at": [look_at.x, look_at.y, look_at.z],
		"fov_deg": _fov, "up": [0.0, 1.0, 0.0], "notes": "",
	}


## Jump to an explicit pose. Accepts either `{"position","look_at","fov_deg"}` (CameraPoseRegistry
## shape) or `{"position","rotation_euler_deg","fov_deg"}` -- whichever a caller already has on hand.
func set_pose(pose: Dictionary) -> void:
	if not pose.has("position"):
		return
	var p: Array = pose["position"]
	global_position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if pose.has("look_at"):
		var la: Array = pose["look_at"]
		var target := Vector3(float(la[0]), float(la[1]), float(la[2]))
		if target.distance_to(global_position) > 0.0001:
			look_at(target, Vector3.UP)
			_yaw = rotation.y
			_pitch = rotation.x
	elif pose.has("rotation_euler_deg"):
		var r: Array = pose["rotation_euler_deg"]
		rotation = Vector3(deg_to_rad(float(r[0])), deg_to_rad(float(r[1])), deg_to_rad(float(r[2])))
		_yaw = rotation.y
		_pitch = rotation.x
	_fov = float(pose.get("fov_deg", _fov))
	emit_signal("pose_changed", get_pose())


func save_pose(pose_name: String) -> Dictionary:
	var pose := get_pose()
	pose["name"] = pose_name
	_poses[pose_name] = pose
	_write_all_poses()
	_refresh_pose_list_label()
	return pose


func load_pose(pose_name: String) -> bool:
	if not _poses.has(pose_name):
		return false
	set_pose(_poses[pose_name])
	return true


func list_poses() -> Array:
	var out := _poses.keys()
	out.sort()
	return out


## Requires `build_preview == true` (the default); returns null when the preview viewport was
## skipped (DQ-0343912a additive change) rather than crashing a caller that forgot to check.
func preview_texture() -> ViewportTexture:
	if _preview_viewport == null:
		return null
	return _preview_viewport.get_texture()


func _cycle_pose(direction: int) -> void:
	var names := list_poses()
	if names.is_empty():
		return
	_cursor_index = wrapi(_cursor_index + direction, 0, names.size())
	load_pose(names[_cursor_index])


func _toggle_popout_window() -> void:
	if _popup_window and is_instance_valid(_popup_window):
		_popup_window.queue_free()
		_popup_window = null
		return
	_popup_window = Window.new()
	_popup_window.title = "ViewpointPicker preview"
	_popup_window.size = pip_size
	_popup_window.close_requested.connect(func():
		if _popup_window and is_instance_valid(_popup_window):
			_popup_window.queue_free()
		_popup_window = null)
	var rect := TextureRect.new()
	rect.texture = _preview_viewport.get_texture()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_popup_window.add_child(rect)
	add_child(_popup_window)
	_popup_window.popup()


func _load_all_poses() -> void:
	_poses = {}
	if FileAccess.file_exists(poses_path):
		var f := FileAccess.open(poses_path, FileAccess.READ)
		if f:
			var text := f.get_as_text()
			f.close()
			var parsed = JSON.parse_string(text)
			if parsed is Dictionary and parsed.has("poses"):
				for entry in parsed["poses"]:
					if entry is Dictionary and entry.has("name"):
						_poses[String(entry["name"])] = entry
	_refresh_pose_list_label()


func _write_all_poses() -> void:
	var f := FileAccess.open(poses_path, FileAccess.WRITE)
	if f == null:
		return
	var data := {"schema_version": 1, "poses": _poses.values()}
	f.store_string(JSON.stringify(data, "  "))
	f.close()


func _refresh_pose_list_label() -> void:
	if _pose_list_label == null:
		return
	var names := list_poses()
	_pose_list_label.text = ("poses: (none saved yet)" if names.is_empty()
		else "poses: " + ", ".join(names))
