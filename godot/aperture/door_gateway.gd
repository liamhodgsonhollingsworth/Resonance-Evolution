extends Node3D
## DOOR / GATEWAY — a physical portal you WALK INTO to enter another scene (Liam spec 2026-07-05
## item 4: "you put a physical door or gateway in the world that I can enter to go into the scene
## (and to leave is wired to escape for now)"). This is the IN-WORLD alternative to a 2D scene_link
## card — the same destination, reached by stepping through a doorway instead of clicking a tile.
##
## DATA-DRIVEN: a door carries its target as a plain dict (the SceneTransition target shape), so a
## door can be dropped for ANY scene with no new code:
##     door.configure({
##       "scene": "res://examples/aperture_explore_scene.tscn",  # REQUIRED
##       "same_window": true,        # stable → same window (seamless); omit → derived from experimental
##       "experimental": false,      # breakable-system scene → new godot window
##       "label": "Explore gallery", # shown on the door frame + lintel sign
##       "color": [0.5, 0.75, 1.0],  # frame accent (optional)
##       "params": {…}               # forwarded to the target (optional)
##     })
##
## The door builds a visible frame + a glowing threshold + a floating lintel sign. Crossing the
## threshold emits `entered(target)` ONCE (re-armed only after the player steps back out), which the
## room hands to SceneTransition.enter — the room owns the actual transition so a headless test can
## drive the door without a SceneTree scene-change. No physics body: entry is a cheap distance test
## the room polls (arm_on_enter), so the door works with the room's fly-camera "player" too.
##
## No class_name (mistake #046): the room preload()s this file by path.

signal entered(target: Dictionary)

const ENTER_RADIUS := 1.1          # how close the player's XZ centre must get to trigger
const REARM_RADIUS := 2.2          # must leave this far before the door can trigger again

var target: Dictionary = {}
var label_text := ""
var accent := Color(0.5, 0.75, 1.0)

var _armed := true                 # false right after a trigger, until the player steps back out
var _built := false


## Configure the door from its target dict (call before or after adding to the tree).
func configure(cfg: Dictionary) -> void:
	target = cfg.duplicate(true)
	label_text = String(cfg.get("label", cfg.get("scene", "scene")))
	var col = cfg.get("color", null)
	if typeof(col) == TYPE_ARRAY and (col as Array).size() >= 3:
		accent = Color(col[0], col[1], col[2])
	if _built:
		_refresh_visuals()


func _ready() -> void:
	if not _built:
		_build()


## The room calls this each frame with the player position. Crossing the threshold (XZ distance <
## ENTER_RADIUS) fires `entered(target)` once; the door re-arms only after the player leaves
## REARM_RADIUS, so you do not immediately re-trigger on return / on a same-window fade-in.
func poll_player(player_pos: Vector3) -> bool:
	if target.is_empty():
		return false
	var d := Vector2(player_pos.x - global_position.x, player_pos.z - global_position.z).length()
	if _armed and d < ENTER_RADIUS:
		_armed = false
		entered.emit(target)
		return true
	if not _armed and d > REARM_RADIUS:
		_armed = true
	return false


func _build() -> void:
	_built = true
	# Two jambs + a lintel (a simple archway frame).
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.16, 0.17, 0.2)
	frame_mat.roughness = 0.7
	for x in [-0.85, 0.85]:
		var jamb := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 2.6, 0.3)
		jamb.mesh = bm
		jamb.position = Vector3(x, 1.3, 0.0)
		jamb.material_override = frame_mat
		add_child(jamb)
	var lintel := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(2.3, 0.35, 0.35)
	lintel.mesh = lm
	lintel.position = Vector3(0.0, 2.75, 0.0)
	lintel.material_override = frame_mat
	add_child(lintel)
	# The glowing threshold "portal" pane between the jambs — the walk-through target.
	var pane := MeshInstance3D.new()
	pane.name = "Pane"
	var pm := BoxMesh.new()
	pm.size = Vector3(1.5, 2.4, 0.08)
	pane.mesh = pm
	pane.position = Vector3(0.0, 1.3, 0.0)
	add_child(pane)
	# A soft light so the doorway reads as an active portal in the room.
	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.position = Vector3(0.0, 1.4, 0.4)
	glow.omni_range = 4.0
	glow.light_energy = 1.6
	add_child(glow)
	# Floating lintel sign.
	var sign := Label3D.new()
	sign.name = "Sign"
	sign.pixel_size = 0.004
	sign.font_size = 48
	sign.position = Vector3(0.0, 3.25, 0.0)
	sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(sign)
	# A subtle "walk in" hint under the sign.
	var hint := Label3D.new()
	hint.name = "Hint"
	hint.text = "walk in →  (ESC to leave)"
	hint.pixel_size = 0.0028
	hint.font_size = 32
	hint.modulate = Color(0.6, 0.66, 0.72)
	hint.position = Vector3(0.0, 0.35, 0.55)
	hint.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(hint)
	_refresh_visuals()


func _refresh_visuals() -> void:
	var pane := get_node_or_null("Pane") as MeshInstance3D
	if pane != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(accent.r, accent.g, accent.b, 0.55)
		mat.emission_enabled = true
		mat.emission = accent
		mat.emission_energy_multiplier = 0.9
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pane.material_override = mat
	var glow := get_node_or_null("Glow") as OmniLight3D
	if glow != null:
		glow.light_color = accent
	var sign := get_node_or_null("Sign") as Label3D
	if sign != null:
		sign.text = label_text
		sign.modulate = accent.lightened(0.3)
