extends RefCounted
## STICKY NOTE — the first HELD TOOL (the item the spec asks to build now).
##
## Spec (Liam, 2026-07-03 verbatim):
##   "give me a sticky note object that I can stick onto any node that I am looking at, it sticks
##    that the exact point that I am looking at (and should give me a little preview orb/point
##    that I can see when holding it that shows where it will be stuck, then I can type on it. It
##    doesn't have to render yet, but eventually it should render as a physical sticky note (can
##    just be a small curved/flat orange square)."
##
## BEHAVIOR (as a held-item handler — see sandbox_items.gd for the seam contract):
##   while_held : raycast from the camera to the EXACT surface point under the crosshair and show
##                a small PREVIEW ORB there (the "little preview orb/point ... that shows where it
##                will be stuck"). Green when it will hit a stickable surface, dim when it won't.
##   primary (LEFT click)  : stick the note at that exact point, then open the text editor.
##   secondary (RIGHT click): nothing special (a note is not "placed" like a block) — falls back
##                to nothing here so an accidental right-click doesn't drop a block.
##   middle : falls through to the MC pick default (so you can still middle-click-pick while
##                holding the note — the note tool does not override middle).
##
## THE ANCHOR (survives the target moving — spec: "sticks ... to any node ... at the exact point"):
##   A note stores its target as { object_id | cell } PLUS a LOCAL-space anchor point and face
##   normal (local to the hit object's transform). The physical orange square is re-placed every
##   frame from target.global_transform * local_anchor, so when a stuck-on object is grabbed /
##   rotated / scaled, its notes ride along. Notes stuck on a fixed block cell use the cell's
##   world transform (blocks don't move, but the same local-anchor math applies uniformly).
##
## RENDER (approved for now): a small FLAT ORANGE SQUARE (QuadMesh) oriented to the face normal,
##   at the anchor. "Can just be a small curved/flat orange square" — this is that. A future
##   richer note render swaps the mesh; the anchor/persistence code does not change.
##
## PERSISTENCE: notes append to the notes.jsonl handoff channel (ADDITIVELY extends the RE #145
##   row schema — every prior field kept; anchor point/normal + held-item provenance added) AND
##   ride inside the world save so they reload with the world. Both paths go through the controller
##   (ctrl.stick_note / ctrl.save_note_row) so this handler stays persistence-agnostic.
##
## No class_name (mistake #046): consumers preload() this file by path.

const ORANGE := Color(0.98, 0.55, 0.10)

var _orb: MeshInstance3D = null                 # the while-held preview orb (owned by the controller's HUD-3D root)
var _last_hit := {}                             # cached last raycast hit (so primary sticks exactly where the orb showed)


## Called each frame while the sticky note is the held item. Show the preview orb at the exact
## surface point the crosshair is on.
func while_held(ctrl, _delta: float) -> void:
	_ensure_orb(ctrl)
	var hit: Dictionary = ctrl.surface_pick()      # { hit:bool, point:Vector3, normal:Vector3, target:{...} }
	_last_hit = hit
	if _orb == null:
		return
	if bool(hit.get("hit", false)):
		_orb.visible = true
		_orb.global_position = hit["point"]
		var m := _orb.material_override as StandardMaterial3D
		if m != null:
			m.albedo_color = Color(0.35, 1.0, 0.45, 0.9)   # green: will stick here
	else:
		_orb.visible = false


## LEFT click while holding the note: stick it at the previewed point, then open the editor.
func primary(ctrl) -> void:
	var hit: Dictionary = _last_hit if not _last_hit.is_empty() else ctrl.surface_pick()
	if not bool(hit.get("hit", false)):
		ctrl.flash("aim at a surface to stick the note")
		return
	# Ask the controller to create the note anchor (it owns the world/objects + the render + save).
	var note_id: String = ctrl.stick_note(hit)
	if note_id == "":
		ctrl.flash("could not stick note here")
		return
	ctrl.open_note_editor(note_id)                  # type on it (Enter saves, ESC cancels)


## RIGHT click while holding the note: deliberately a no-op (a note is not a placeable block).
func secondary(_ctrl) -> void:
	pass


## When you switch away from the sticky note, hide/free its preview orb.
func on_deselect(ctrl) -> void:
	if _orb != null and is_instance_valid(_orb):
		_orb.queue_free()
	_orb = null
	_last_hit = {}


func on_select(ctrl) -> void:
	ctrl.flash("Sticky note: aim at anything, LEFT click to stick, then type")


func _ensure_orb(ctrl) -> void:
	if _orb != null and is_instance_valid(_orb):
		return
	_orb = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	_orb.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 1.0, 0.45, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_orb.material_override = mat
	_orb.visible = false
	ctrl.add_preview_child(_orb)                    # controller parents it under a HUD-3D root


## Build the flat orange square mesh instance for a stuck note (called by the controller when it
## realizes a note anchor into the scene). Kept HERE so the note's visual lives with the note.
static func make_note_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.35, 0.35)                    # a small square
	mi.mesh = q
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ORANGE
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED    # visible from both sides
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mi.material_override = mat
	return mi
