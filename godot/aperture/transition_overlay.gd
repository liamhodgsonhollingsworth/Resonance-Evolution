extends CanvasLayer
## TRANSITION OVERLAY — a SELF-CONTAINED, root-parented layer that a same-window scene transition
## installs so the destination scene needs to cooperate in NO way (Liam 2026-07-05 defect #5: the
## sandbox door led to a "black screen that doesn't move or update"). The prior design required the
## incoming scene to call SceneTransition.fade_in_on_ready(self) to remove the black fade cover — but
## only aperture_3d.gd did that, so a same-window swap into sandbox_creative / gallery / the explorer
## left the OPAQUE, input-eating fade cover on the tree root FOREVER: a black, frozen, unresponsive
## screen with the real scene running invisibly underneath. This layer fixes that at the source:
##
##   * It is parented on the tree ROOT (survives change_scene_to_file), at a HIGH layer, ABOVE the
##     swapped scene.
##   * It fades ITSELF out and frees the black cover a couple of frames after the new scene is up —
##     the destination scene does nothing. So the swap is seamless AND never leaves a stuck cover.
##   * It gives every same-window destination a working LEAVE = ESC (spec item 4: "to leave is wired
##     to escape for now") by catching ESC and changing the scene back to the aperture room — WITHOUT
##     editing any destination scene (gallery.gd / sandbox_creative.gd / explore are read-only reuse).
##     A tiny always-visible ribbon makes the exit discoverable.
##
## No class_name (mistake #046): preload()ed by path from scene_transition.gd.

const APERTURE_ROOM := "res://aperture/aperture_3d.tscn"
const OVERLAY_NAME := "__aperture_transition_overlay"

var _rect: ColorRect                 # the black fade cover
var _fade_seconds := 0.35
var _return_scene := APERTURE_ROOM   # where ESC goes (the room we came from)
var _phase := "cover"                # cover -> settle (wait for new scene) -> fade_out -> live
var _settle_frames := 0
var _leaving := false


## Build the overlay: an opaque-capable black cover + a discoverable "ESC -> back to the room" ribbon.
## `return_scene` is the res:// scene ESC returns to (defaults to the aperture room). Called by the
## transition BEFORE change_scene_to_file, on the tree root, so it outlives the swap.
func setup(fade_seconds: float, return_scene: String) -> void:
	name = OVERLAY_NAME
	layer = 200                      # above the fade layer AND the swapped scene
	_fade_seconds = maxf(fade_seconds, 0.0)
	if return_scene != "":
		_return_scene = return_scene
	_rect = ColorRect.new()
	_rect.color = Color(0, 0, 0, 0)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # DO NOT eat input once faded out (defect #5)
	add_child(_rect)
	var ribbon := Label.new()
	ribbon.name = "Ribbon"
	ribbon.text = "  ESC -> back to the aperture room  "
	ribbon.add_theme_font_size_override("font_size", 13)
	ribbon.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0.05, 0.07, 0.11, 0.82)
	rs.set_corner_radius_all(6)
	rs.content_margin_left = 8; rs.content_margin_right = 8
	rs.content_margin_top = 4; rs.content_margin_bottom = 4
	ribbon.add_theme_stylebox_override("normal", rs)
	ribbon.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 8)
	ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ribbon.visible = false           # shown once the destination is live
	add_child(ribbon)
	# Process + input keep running across the scene swap because we live on the root, not the scene.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	set_process_input(true)


## Begin fully black (called right before the scene swap so the swap frame is hidden).
func arm_cover() -> void:
	if _rect != null:
		_rect.color = Color(0, 0, 0, 1)
	_phase = "settle"
	_settle_frames = 0


func _process(delta: float) -> void:
	match _phase:
		"settle":
			# Let the new scene get a few frames up (build its camera / viewport) before revealing it,
			# so we never flash a half-built frame. Then fade the cover out.
			_settle_frames += 1
			if _settle_frames >= 3:
				_phase = "fade_out"
		"fade_out":
			if _rect == null:
				_go_live()
				return
			# Fade the black cover out. Cap the effective step so a single huge frame (a heavy scene's
			# _ready) can't jump erratically; a floor keeps it always progressing so it never stalls.
			var step := clampf(delta, 1.0 / 120.0, 1.0 / 20.0) / maxf(_fade_seconds, 0.01)
			var a := _rect.color.a - step
			_rect.color = Color(0, 0, 0, maxf(a, 0.0))
			if a <= 0.0:
				_go_live()
		_:
			pass


## Cover fully removed: stop eating any input, reveal the ESC ribbon, and stop fading.
func _go_live() -> void:
	_phase = "live"
	if _rect != null:
		_rect.color = Color(0, 0, 0, 0)
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ribbon := get_node_or_null("Ribbon")
	if ribbon is Control:
		(ribbon as Control).visible = true


func _input(event: InputEvent) -> void:
	if _leaving:
		return
	# ESC LEAVES the same-window destination and returns to the room. We do this from the overlay so no
	# destination scene needs editing (read-only reuse). Allowed as soon as the destination is up (any
	# phase past the initial "cover"), so a keen ESC during the fade-in still leaves — leaving is never
	# blocked. (During "cover" we are still fading TO black before the swap; ESC there is a no-op.)
	if _phase == "cover":
		return
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not (key.pressed and not key.echo and key.keycode == KEY_ESCAPE):
		return
	_leaving = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var tree := get_tree()
	if tree == null:
		return
	# Fade back to black under cover, then swap to the room; the room's own transition fade-in
	# (it calls SceneTransition.fade_in_on_ready) resolves the arrival smoothly.
	if _rect != null:
		_rect.mouse_filter = Control.MOUSE_FILTER_STOP
		var tw := tree.create_tween()
		tw.tween_property(_rect, "color:a", 1.0, 0.18)
		tw.tween_callback(func():
			tree.change_scene_to_file(_return_scene)
			queue_free())
	else:
		tree.change_scene_to_file(_return_scene)
		queue_free()
	get_viewport().set_input_as_handled()
