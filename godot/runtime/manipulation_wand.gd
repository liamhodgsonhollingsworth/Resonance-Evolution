extends RefCounted
## MANIPULATION WAND — the PRECISE move + rotate held tool (the "particular tool" Liam asked for).
##
## Spec (Liam 2026-07-03 verbatim, sandbox UI Q/A):
##   "for object manipulation, queue up a stick/wand that gives me advanced motion/orientation
##    control over objects that appear when I right click and I interact with using left click"
## Spec (Liam 2026-07-05, item 3): a PRECISE move + rotate tool — "fine increments (e.g. mouse-drag
##   along an axis for move, scroll/keys to rotate in small steps, optional snap toggle), grid-free …
##   Precision is the whole point: Liam must place things exactly to build a room/scene."
##
## THE MODEL (a held-item handler — see sandbox_items.gd for the seam contract):
##   RIGHT click : ENGAGE the aimed-at object — the wand's controls "appear on right click". This
##                 grabs that object as the manipulation target and shows the 3-axis gizmo + a small
##                 control HUD. Right-clicking again (or aiming at nothing) DISENGAGES.
##   LEFT click  : "interact using left click" — while engaged, CYCLE the active axis X → Y → Z (the
##                 axis a drag moves along and a rotate turns around). While not engaged, left click
##                 engages the aimed-at object too (so a single click also works).
##   MOUSE DRAG  : hold LEFT and drag → PRECISE MOVE of the target along the active axis. Grid-free:
##                 the delta is continuous (mouse pixels × move_sensitivity metres/px). Fine control.
##   SCROLL / [ ]: ROTATE the target around the active axis in SMALL STEPS (rotate_step_deg, default
##                 5°). Scroll up / ] = +step, scroll down / [ = −step.
##   , / .       : nudge-MOVE one precise step (move_step) along the active axis (keyboard fine move).
##   G           : toggle SNAP (optional, off by default) — snaps move to snap_move_m and rotate to
##                 snap_rot_deg. Grid-free is the DEFAULT (per the free-placement spec); snap is opt-in.
##   [ + / - ]   : (via , / . handled above) — kept minimal; scale is NOT this tool's job (the spec is
##                 move + rotate). Scale stays on the debug verb layer.
##
## WRITES (pure DATA on the object record — the transform is a function of the record, per the engine
## design law): MOVE writes `base_pos` (Vector3); ROTATE writes `yaw_deg` (Y) / `pitch_deg` (X) /
## `roll_deg` (Z). sandbox_behaviors.tick composes all three into the node's Basis every frame, so the
## wand never touches the node directly — it edits data and the existing tick applies it. Because the
## fields are the same ones _serialize_world persists, a wand-manipulated object round-trips through
## save/reload for free.
##
## GRID-FREE precision: move deltas are continuous metres (no _world_to_cell snap); rotate is in exact
## degrees. Snap is an explicit opt-in toggle, never the default.
##
## No class_name (mistake #046): consumers preload() this file by path.

# ── tunables (a later params/inventory-entry override can set these; sensible precise defaults now) ──
var move_sensitivity := 0.01     # metres per pixel of mouse drag (fine — 100 px ≈ 1 m)
var move_step := 0.05            # metres per , / . keyboard nudge (precise)
var rotate_step_deg := 5.0       # degrees per scroll / [ ] step (small)
var snap_move_m := 0.25          # snap-move increment when snap is ON
var snap_rot_deg := 15.0         # snap-rotate increment when snap is ON

# ── engaged state ──
var _target_id := ""             # the object the wand is manipulating ("" = not engaged)
var _axis := 0                   # 0=X, 1=Y, 2=Z (the active move/rotate axis)
var _snap := false               # snap toggle (off by default — grid-free precision is the default)
var _dragging := false           # LEFT held: a drag-move is in progress
var _gizmo: Node3D = null        # the 3-axis gizmo drawn at the target (owned via ctrl.add_preview_child)
const AXIS_NAMES := ["X", "Y", "Z"]
const AXIS_VEC := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
const AXIS_COL := [Color(1, 0.25, 0.25), Color(0.3, 1, 0.35), Color(0.35, 0.55, 1)]


func on_select(ctrl) -> void:
	ctrl.flash("Wand: RIGHT-click an object to grab it · LEFT-click cycles axis · drag=move · scroll/[ ]=rotate · G=snap")


func on_deselect(ctrl) -> void:
	_disengage(ctrl)


# ── RIGHT click: engage the aimed-at object (controls "appear on right click") ────────────────────────
func secondary(ctrl) -> void:
	var id := _aimed_object(ctrl)
	if id == "":
		_disengage(ctrl)
		ctrl.flash("Wand: aim at a placed object, then RIGHT-click to grab it")
		return
	if id == _target_id:
		_disengage(ctrl)                     # right-click the same object again => release it
		return
	_engage(ctrl, id)


# ── LEFT click: cycle the active axis while engaged; engage if not yet engaged ────────────────────────
func primary(ctrl) -> void:
	if _target_id == "" or not ctrl.objects.has(_target_id):
		var id := _aimed_object(ctrl)
		if id != "":
			_engage(ctrl, id)
		return
	_axis = (_axis + 1) % 3
	_refresh_gizmo(ctrl)
	ctrl.flash("Wand axis: %s   (drag=move · scroll/[ ]=rotate)" % AXIS_NAMES[_axis])


# ── per-frame: keep the gizmo on the (possibly moving) target ─────────────────────────────────────────
func while_held(ctrl, _delta: float) -> void:
	if _target_id != "" and not ctrl.objects.has(_target_id):
		_disengage(ctrl)                     # the target was deleted from under us
		return
	if _gizmo != null and is_instance_valid(_gizmo) and _target_id != "":
		_gizmo.global_position = _target_world_pos(ctrl)


# ── keyboard hook (dispatched by the controller only for handlers that define it) ─────────────────────
## Return true if the key was consumed. G=snap, [ / ]=rotate step, , / . =precise move nudge,
## TAB=cycle axis (a keyboard alternative to left-click), ESC=release.
func key(ctrl, event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	match event.keycode:
		KEY_G:
			_snap = not _snap
			ctrl.flash("Wand snap %s (move %.2fm · rot %.0f°)" % ["ON" if _snap else "OFF", snap_move_m, snap_rot_deg])
			return true
		KEY_TAB:
			if _target_id != "":
				_axis = (_axis + 1) % 3
				_refresh_gizmo(ctrl)
				ctrl.flash("Wand axis: %s" % AXIS_NAMES[_axis])
				return true
		KEY_BRACKETRIGHT:
			_rotate(ctrl, _rot_increment())
			return true
		KEY_BRACKETLEFT:
			_rotate(ctrl, -_rot_increment())
			return true
		KEY_PERIOD:
			_move(ctrl, _move_increment())
			return true
		KEY_COMMA:
			_move(ctrl, -_move_increment())
			return true
		KEY_ESCAPE:
			if _target_id != "":
				_disengage(ctrl)
				return true
	return false


# ── mouse hooks (dispatched by the controller only for handlers that define them) ─────────────────────
## A LEFT-button press/release toggles drag-move; wheel rotates. Return true if consumed. (The plain
## primary()/secondary() click hooks still fire for press events; this sees BOTH press and release so a
## drag can begin/end.)
func mouse_button(ctrl, event: InputEventMouseButton) -> bool:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _target_id != "":
			_dragging = true
			# primary() (axis cycle) already fired on this same press; a drag that follows moves along
			# the NEW axis, which is the intuitive behavior.
			return false
		if not event.pressed:
			_dragging = false
			return false
	if not event.pressed:
		return false
	if _target_id == "":
		return false
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_rotate(ctrl, _rot_increment())
		return true
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_rotate(ctrl, -_rot_increment())
		return true
	return false


## Mouse motion while LEFT is held → precise move along the active axis.
func mouse_motion(ctrl, event: InputEventMouseMotion) -> bool:
	if not _dragging or _target_id == "":
		return false
	# Use the larger-magnitude screen axis so both horizontal and vertical drags feel natural; the sign
	# follows rightward / upward drag = positive along the axis.
	var d := event.relative.x - event.relative.y
	_move(ctrl, d * move_sensitivity)
	return true


# ══ core precise edits (pure DATA writes on the record) ═══════════════════════════════════════════════

## MOVE the target `amount` metres along the active world axis. Grid-free (continuous), unless snap.
func _move(ctrl, amount: float) -> void:
	if _target_id == "" or not ctrl.objects.has(_target_id):
		return
	var rec: Dictionary = ctrl.objects[_target_id]
	var pos: Vector3 = rec.get("base_pos", Vector3.ZERO)
	pos += (AXIS_VEC[_axis] as Vector3) * amount
	if _snap:
		var step := maxf(snap_move_m, 1e-4)
		pos = Vector3(roundf(pos.x / step) * step, roundf(pos.y / step) * step, roundf(pos.z / step) * step)
	rec["base_pos"] = pos
	ctrl.flash("move %s → %.3f, %.3f, %.3f" % [AXIS_NAMES[_axis], pos.x, pos.y, pos.z])


## ROTATE the target `deg` degrees around the active axis (X→pitch, Y→yaw, Z→roll). Small steps.
func _rotate(ctrl, deg: float) -> void:
	if _target_id == "" or not ctrl.objects.has(_target_id):
		return
	var rec: Dictionary = ctrl.objects[_target_id]
	var field := ["pitch_deg", "yaw_deg", "roll_deg"][_axis]
	var v := fmod(float(rec.get(field, 0.0)) + deg, 360.0)
	if _snap:
		var step := maxf(snap_rot_deg, 0.01)
		v = roundf(v / step) * step
	rec[field] = v
	ctrl.flash("rotate %s → %.1f°" % [AXIS_NAMES[_axis], v])


func _rot_increment() -> float:
	return snap_rot_deg if _snap else rotate_step_deg

func _move_increment() -> float:
	return snap_move_m if _snap else move_step


# ══ engage / disengage + gizmo ════════════════════════════════════════════════════════════════════════

func _engage(ctrl, id: String) -> void:
	_target_id = id
	_axis = 0
	ctrl.wand_set_selection(id)              # let the controller draw its selection marker on the target
	_refresh_gizmo(ctrl)
	var rec: Dictionary = ctrl.objects[id]
	ctrl.flash("Wand grabbed %s — axis %s · drag=move · scroll/[ ]=rotate · G=snap · RIGHT-click=release" % [ctrl._obj_label(rec), AXIS_NAMES[_axis]])


func _disengage(ctrl) -> void:
	_target_id = ""
	_dragging = false
	if _gizmo != null and is_instance_valid(_gizmo):
		_gizmo.queue_free()
	_gizmo = null
	if ctrl != null and ctrl.has_method("wand_set_selection"):
		ctrl.wand_set_selection("")


## The object under the crosshair right now ("" if none) — the controller owns the pick.
func _aimed_object(ctrl) -> String:
	var pick: Dictionary = ctrl._pick_object()
	return String(pick.get("id", ""))


func _target_world_pos(ctrl) -> Vector3:
	if _target_id == "" or not ctrl.objects.has(_target_id):
		return Vector3.ZERO
	var rec: Dictionary = ctrl.objects[_target_id]
	var node = rec.get("node")
	if node != null and is_instance_valid(node):
		return (node as Node3D).global_position
	return rec.get("base_pos", Vector3.ZERO)


## Build / refresh the 3-axis gizmo (three coloured arms; the ACTIVE axis is brighter + longer) so it is
## obvious which axis a drag/rotate acts on. Purely a visual aid — headless skips it.
func _refresh_gizmo(ctrl) -> void:
	if ctrl._headless:
		return
	if _gizmo == null or not is_instance_valid(_gizmo):
		_gizmo = Node3D.new()
		_gizmo.name = "WandGizmo"
		ctrl.add_preview_child(_gizmo)
	for c in _gizmo.get_children():
		c.queue_free()
	for a in 3:
		var arm := MeshInstance3D.new()
		var active := (a == _axis)
		var length := 1.4 if active else 0.9
		var thick := 0.05 if active else 0.03
		var cyl := CylinderMesh.new()
		cyl.top_radius = thick
		cyl.bottom_radius = thick
		cyl.height = length
		arm.mesh = cyl
		var mat := StandardMaterial3D.new()
		var col: Color = AXIS_COL[a]
		mat.albedo_color = col if active else Color(col.r, col.g, col.b, 0.55)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		arm.material_override = mat
		# Orient the cylinder (default +Y) to the axis and offset it half-length out along that axis.
		var dir: Vector3 = AXIS_VEC[a]
		if a == 0:      # X
			arm.rotation = Vector3(0, 0, -PI / 2)
		elif a == 2:    # Z
			arm.rotation = Vector3(PI / 2, 0, 0)
		arm.position = dir * (length * 0.5)
		_gizmo.add_child(arm)
	_gizmo.global_position = _target_world_pos(ctrl)


# ── test/introspection helpers (headless asserts read these) ──
func engaged_id() -> String:
	return _target_id

func active_axis() -> int:
	return _axis

func snap_on() -> bool:
	return _snap
