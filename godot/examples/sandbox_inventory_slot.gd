extends Button
## INVENTORY SLOT — a drag-and-drop-aware button for the creative inventory + hotbar.
##
## Spec (Liam, 2026-07-03 verbatim): "The inventory should be drag and drop ... I want the
## inventory to work as close to minecraft default behavior as possible, see if you can find
## duplicated code online or some way to use already done work rather than redoing work."
##
## REUSE DECISION (documented in the report): rather than vendor a third-party addon (GLoot is
## MIT + solid, but it requires an EditorPlugin + registered class_name globals across ~a dozen
## interconnected classes, which fights this repo's no-class_name / preload-by-path convention —
## mistake #046 — and its grid/weight/stack constraints are unneeded for a creative hotbar), this
## uses GODOT'S OWN BUILT-IN Control drag-and-drop — the engine's already-done, MIT, zero-dependency
## mechanism: the virtual methods _get_drag_data / _can_drop_data / _drop_data + set_drag_preview.
## That IS "using already-done work": the drag machinery is the engine's, we only describe the payload.
##
## ROLES (set via `role`):
##   "inventory" : a palette entry in the E-inventory grid. DRAG SOURCE (drag it onto a hotbar slot).
##                 Click also works (MC-creative: click loads it into the ACTIVE hotbar slot).
##   "hotbar"    : one of the 9 hotbar slots. DRAG SOURCE (rearrange) + DROP TARGET (accept a palette
##                 entry from the inventory, or another hotbar slot to swap). Click selects the slot.
##
## The controller (sandbox_creative.gd) wires callbacks + owns the model; this node only carries the
## payload + draws the drag preview. No class_name (mistake #046): the controller preload()s this file.

var ctrl: Node = null                # the sandbox controller (for drop callbacks + thumbnails)
var role := "inventory"              # "inventory" | "hotbar"
var pal_idx := -1                    # palette index this slot currently shows (-1 = empty)
var slot_index := -1                 # for role "hotbar": which of the 9 slots (0..8)


## The drag payload: a dict the drop target inspects. Minimal + self-describing.
func _get_drag_data(_at_position: Vector2) -> Variant:
	if pal_idx < 0:
		return null
	var data := {
		"kind": "sandbox_item",
		"pal_idx": pal_idx,
		"from_role": role,
		"from_slot": slot_index,
	}
	# Drag preview: a small ghost of the slot so the cursor carries a visual (MC-style).
	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(48, 48)
	preview.size = Vector2(48, 48)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if ctrl != null and ctrl.has_method("thumbnail_for"):
		var tex = ctrl.thumbnail_for(pal_idx)
		if tex != null:
			preview.texture = tex
	preview.modulate = Color(1, 1, 1, 0.85)
	set_drag_preview(preview)
	return data


## Only hotbar slots accept drops (the inventory grid is a source, not a target).
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if role != "hotbar":
		return false
	return typeof(data) == TYPE_DICTIONARY and data.get("kind", "") == "sandbox_item"


## Drop resolution: inventory→hotbar sets this slot; hotbar→hotbar swaps.
func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if role != "hotbar" or ctrl == null:
		return
	var from_role := String(data.get("from_role", ""))
	if from_role == "hotbar" and int(data.get("from_slot", -1)) >= 0:
		ctrl._swap_hotbar_slots(int(data["from_slot"]), slot_index)
	else:
		ctrl._set_hotbar_slot(slot_index, int(data.get("pal_idx", -1)))
