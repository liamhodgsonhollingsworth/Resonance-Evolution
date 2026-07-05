extends Node3D
## EXPLORE-A-SCENE demo (Aperture demo #17). Liam verbatim (2026-07-05, item 3):
## "explore around a premade scene that you find on the internet and load in ... go into them and
## pick up and collect assets using the sandbox grab feature and store them in my inventory ...
## walk around a scene and run into solid walls."
##
## WHAT THIS SCENE IS
##   * A first-person EXPLORER: WASD + mouselook + SOLID-WALL collision. The player is the in-house
##     FpsController (a CharacterBody3D) — reused as-is, no fork. Walls are StaticBody3D + a box
##     collider, so you actually RUN INTO them (move_and_slide stops the body); you cannot pass
##     through. Gravity + a floor keep you grounded.
##   * A PREMADE ENVIRONMENT loaded as the world. Preferred: a vendored CC0 glTF scene under
##     res://assets/scenes/<name>/. Fallback (portable, asset-download-free): a procedurally-built
##     WALLED ROOM (four solid primitive walls) dressed with the already-imported Kenney/Quaternius
##     CC0 nature props — so the explore + collide + collect loop is provable BEFORE any heavy scene
##     is approved. When Liam approves a scene, dropping its GLB in and setting SCENE_GLB is the only
##     change; the mechanic is unchanged.
##   * COLLECTIBLES scattered in the room. Each is a real scene Node3D built from a renderer-neutral
##     scene_node descriptor (the same DATA the renderer + inventory speak), registered as a walk-up
##     pickable through ExploreGrabAdapter — the sandbox GRAB + INVENTORY feature, imported READ-ONLY
##     from the peer lane (walkabout/pickup_interactor.gd) via the adapter. Walk up, press E, it's in
##     your inventory (bottom-left HUD). This is the SAME grab used everywhere else — not a re-impl.
##   * IN-SCENE FEEDBACK: press F1 to open a note box; what you type is appended to
##     Alethea-cc/state/sandbox/notes.jsonl keyed to this scene id — the SAME feedback substrate as
##     Aperture card feedback, so notes from inside the scene route the same way.
##
## LAUNCH (windowed, walkable) — opened from the Aperture board as a scene_link, or directly:
##   <godot> --path godot res://examples/explore/explore_scene_demo.tscn
## HEADLESS smoke test:
##   <godot> --headless --path godot -s res://headless_explore_test.gd

const GrabAdapter := preload("res://examples/explore/explore_grab_adapter.gd")
const FpsControllerScript := preload("res://walkabout/fps_controller.gd")
const RendererScript := preload("res://renderers/godot_scene_renderer.gd")

const SCENE_ID := "explore_scene_demo"
const NOTES_REL := "Alethea-cc/state/sandbox/notes.jsonl"   # relative to the Wavelet repo root

## Set to a vendored CC0 environment GLB (res://assets/scenes/<name>/scene.glb) once one is approved
## + imported. Empty → the portable procedural walled-room fallback below is built instead. Either
## way the explorer mechanic is identical.
const SCENE_GLB := ""

## Room geometry (the fallback environment): a square walled room the player is spawned inside.
const ROOM_HALF := 12.0     # half the interior extent (meters) — room is 24m square
const WALL_HEIGHT := 4.0
const WALL_THICK := 0.5
const PICKUP_RADIUS := 2.5  # walk within this many meters to grab (matches the sandbox default)

var _player: CharacterBody3D
var _grab: ExploreGrabAdapter
var _feedback: CanvasLayer
var _renderer: Node          # GodotSceneRenderer instance (for build_node — used statically here)
var _shot_frames := 0

func _ready() -> void:
	_build_environment()
	_build_player()
	# Grab + inventory come from the peer lane through the adapter (READ-ONLY import). The player is
	# the proximity anchor; placed objects (if any) rejoin THIS root.
	_grab = GrabAdapter.new()
	_grab.name = "Grab"
	add_child(_grab)
	_grab.setup(self, _player, self)
	_scatter_collectibles()
	_build_feedback_ui()
	print("[explore] ready; env=%s; %d collectible(s) registered; player at %s" % [
		("glb:" + SCENE_GLB) if SCENE_GLB != "" else "procedural_room",
		_grab.pickable_count(), str(_player.global_position)])

# --- ENVIRONMENT: premade GLB scene, else a procedural WALLED ROOM ---------------------------------

func _build_environment() -> void:
	_add_lighting()
	_add_floor()
	if SCENE_GLB != "" and ResourceLoader.exists(SCENE_GLB, "") or (SCENE_GLB != "" and FileAccess.file_exists(SCENE_GLB)):
		if _load_premade_scene(SCENE_GLB):
			return   # a real premade environment supplies its own walls/props
	_build_walled_room()

## Load a vendored premade GLB as the environment, wrapping its static geometry in trimesh colliders
## so its walls are SOLID (you run into them). Runtime GLTF load (not ResourceLoader) so it works
## with or without a warmed .godot import cache — the #145 pattern (GodotSceneRenderer._load_glb).
func _load_premade_scene(glb_path: String) -> bool:
	var abs := ProjectSettings.globalize_path(glb_path)
	if not FileAccess.file_exists(abs):
		return false
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(abs, state) != OK:
		push_warning("[explore] failed to load premade scene: %s" % glb_path)
		return false
	var scene := doc.generate_scene(state)
	if scene == null:
		return false
	var env := Node3D.new()
	env.name = "PremadeScene"
	env.add_child(scene)
	add_child(env)
	# Make every mesh in the premade scene a SOLID collider so walls actually stop the player.
	_add_static_colliders(env)
	return true

## Walk the premade scene's meshes and give each a trimesh StaticBody3D collider (concave, exact),
## so arbitrary premade-scene geometry becomes solid without hand-authoring collision.
func _add_static_colliders(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			(n as MeshInstance3D).create_trimesh_collision()
		for c in n.get_children():
			stack.append(c)

## The portable fallback environment: four SOLID walls forming a room, so "run into solid walls" is
## demonstrated with zero downloaded assets. Each wall is a StaticBody3D with a BoxShape3D collider
## (the physics wall) + a MeshInstance3D (what you see). The CharacterBody3D player collides with the
## box and stops — you cannot walk through.
func _build_walled_room() -> void:
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.42, 0.40, 0.46)
	# Two walls along X (north/south), two along Z (east/west). Positions put the inner face at ±HALF.
	var span := ROOM_HALF * 2.0 + WALL_THICK
	_add_wall(Vector3(0, WALL_HEIGHT * 0.5, -ROOM_HALF - WALL_THICK * 0.5), Vector3(span, WALL_HEIGHT, WALL_THICK), wall_mat, "WallN")
	_add_wall(Vector3(0, WALL_HEIGHT * 0.5,  ROOM_HALF + WALL_THICK * 0.5), Vector3(span, WALL_HEIGHT, WALL_THICK), wall_mat, "WallS")
	_add_wall(Vector3(-ROOM_HALF - WALL_THICK * 0.5, WALL_HEIGHT * 0.5, 0), Vector3(WALL_THICK, WALL_HEIGHT, span), wall_mat, "WallW")
	_add_wall(Vector3( ROOM_HALF + WALL_THICK * 0.5, WALL_HEIGHT * 0.5, 0), Vector3(WALL_THICK, WALL_HEIGHT, span), wall_mat, "WallE")
	# A couple of interior pillars so there is something to bump into mid-room, too.
	_add_wall(Vector3(-4, WALL_HEIGHT * 0.5, -4), Vector3(1.2, WALL_HEIGHT, 1.2), wall_mat, "PillarA")
	_add_wall(Vector3( 5, WALL_HEIGHT * 0.5,  3), Vector3(1.2, WALL_HEIGHT, 1.2), wall_mat, "PillarB")

func _add_wall(center: Vector3, size: Vector3, mat: StandardMaterial3D, wall_name: String) -> void:
	var body := StaticBody3D.new()
	body.name = wall_name
	body.position = center
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)
	add_child(body)

func _add_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	var mi := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(ROOM_HALF * 2.4, ROOM_HALF * 2.4)
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.20, 0.24)
	mi.material_override = mat
	floor_body.add_child(mi)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(ROOM_HALF * 2.4, 0.2, ROOM_HALF * 2.4)
	col.shape = box
	col.position = Vector3(0, -0.1, 0)
	floor_body.add_child(col)
	add_child(floor_body)

func _add_lighting() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.15
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.52, 0.72)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.82)
	sky_mat.ground_bottom_color = Color(0.22, 0.24, 0.27)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env_node.environment = env
	add_child(env_node)

# --- PLAYER: the in-house first-person controller (walk/look/collision), reused as-is -------------

func _build_player() -> void:
	var player: CharacterBody3D = FpsControllerScript.new()
	player.name = "Player"
	# Spawn near a corner looking diagonally across the room so the opening view frames the whole
	# space (walls, pillars, scattered collectibles) rather than a prop right at the camera. Godot
	# forward is −Z; yaw +135° turns it toward (−X, −Z), i.e. across the room to the far corner.
	player.position = Vector3(ROOM_HALF - 5.0, 1.0, ROOM_HALF - 5.0)
	player.rotation_degrees = Vector3(0, 135, 0)
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	col.shape = cap
	col.position = Vector3(0, 0.9, 0)
	player.add_child(col)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 1.6, 0)
	player.add_child(cam)
	add_child(player)
	_player = player

# --- COLLECTIBLES: CC0 nature props scattered in the room, grabbable via the adapter -------------

## Scatter a handful of already-imported CC0 assets around the room as walk-up pickables. Each is a
## real Node3D built from its renderer-neutral scene_node descriptor (mesh identity = inventory type,
## so two of the same model stack as one inventory row), registered through the grab adapter.
func _scatter_collectibles() -> void:
	var picks := _collectible_descriptors()
	var i := 0
	for entry in picks:
		var desc: Dictionary = entry["desc"]
		var pos: Vector3 = entry["pos"]
		var node: Node3D = RendererScript.build_node(desc)
		if node == null:
			continue
		node.name = "collectible_%d" % i
		add_child(node)
		node.global_position = pos
		var placed_desc := desc.duplicate(true)
		placed_desc["translation"] = [pos.x, pos.y, pos.z]
		_grab.register_pickable("pick_%d_%s" % [i, String(desc.get("name", "item"))], node, PICKUP_RADIUS, placed_desc)
		i += 1

## A small, fixed set of CC0 collectibles + their scatter positions. Drawn from the imported
## Kenney/Quaternius nature kits (via the manifest) so no new download is needed; falls back to a
## primitive gem if the manifest is unavailable, so the loop is never empty.
func _collectible_descriptors() -> Array:
	var out: Array = []
	# Scattered across the interior, kept clear of the corner spawn (near +X/+Z) so nothing clips the
	# opening camera. The player walks up to each to grab it.
	var positions := [
		Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-6, 0, 6),
		Vector3(0, 0, -8), Vector3(-8, 0, 0), Vector3(0, 0, 0),
		Vector3(-3, 0, 2), Vector3(2, 0, -3),
	]
	var glb_paths := _manifest_collectible_paths(positions.size())
	for j in positions.size():
		var desc: Dictionary
		if j < glb_paths.size():
			desc = { "name": glb_paths[j]["name"], "mesh": { "source": "glb", "path": glb_paths[j]["path"] } }
		else:
			# Primitive fallback: a small floating gem (asset-free), still a proper inventory type.
			desc = { "name": "gem", "mesh": { "source": "primitive", "shape": "sphere", "params": { "radius": 0.4 } } }
		out.append({ "desc": desc, "pos": positions[j] })
	return out

## Read up to `limit` GLB collectible paths from the asset manifest (already-imported CC0 kits),
## preferring small props (rocks, trees, plants). Empty if the manifest is missing → primitive path.
func _manifest_collectible_paths(limit: int) -> Array:
	var out: Array = []
	var mp := "res://assets/manifest.json"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(mp)):
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(mp))
	if typeof(data) != TYPE_DICTIONARY:
		return out
	var prefer := ["rock", "pine", "tree", "plant", "flower", "mushroom", "twisted"]
	var assets: Array = data.get("assets", [])
	# Prefer small props, then fill from whatever remains, so the set is stable + not empty.
	var ordered: Array = []
	for a in assets:
		var tags: Array = a.get("tags", [])
		for p in prefer:
			if p in tags:
				ordered.append(a)
				break
	for a in assets:
		if a not in ordered:
			ordered.append(a)
	for a in ordered:
		if out.size() >= limit:
			break
		var nm := String(a.get("name", "item"))
		# Trim the verbose Quaternius suffixes for a clean inventory label.
		if nm.contains("_-_free_model"):
			nm = nm.split("_-_free_model")[0]
		out.append({ "name": nm, "path": String(a.get("path", "")) })
	return out

# --- IN-SCENE FEEDBACK: F1 → note box → append notes.jsonl (same substrate as card feedback) -------

func _build_feedback_ui() -> void:
	_feedback = CanvasLayer.new()
	_feedback.name = "FeedbackLayer"
	_feedback.layer = 20
	add_child(_feedback)
	# A hint pinned top-right so the feedback key is discoverable.
	var hint := Label.new()
	hint.text = "F1  leave a note about this scene"
	hint.add_theme_color_override("font_color", Color(0.8, 0.85, 0.92))
	hint.add_theme_font_size_override("font_size", 12)
	hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	hint.position += Vector2(-260, 12)
	_feedback.add_child(hint)
	# The (hidden) note dialog: a LineEdit in a panel, shown on F1.
	_note_panel = PanelContainer.new()
	_note_panel.visible = false
	_note_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_note_panel.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.95)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	_note_panel.add_theme_stylebox_override("panel", style)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_note_panel.add_child(vb)
	var title := Label.new()
	title.text = "Note about this scene (Enter to send · Esc to cancel)"
	title.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	vb.add_child(title)
	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "what works / what to change…"
	_note_edit.custom_minimum_size = Vector2(430, 0)
	_note_edit.text_submitted.connect(_on_note_submitted)
	vb.add_child(_note_edit)
	_feedback.add_child(_note_panel)

var _note_panel: PanelContainer
var _note_edit: LineEdit

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1:
			_toggle_note_box()
		elif event.keycode == KEY_ESCAPE and _note_panel != null and _note_panel.visible:
			_close_note_box()

func _toggle_note_box() -> void:
	if _note_panel == null:
		return
	if _note_panel.visible:
		_close_note_box()
		return
	_note_panel.visible = true
	# Release the mouse so the field can be clicked/typed (the FPS controller captured it).
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_note_edit.grab_focus()

func _close_note_box() -> void:
	_note_panel.visible = false
	_note_edit.text = ""
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_note_submitted(text: String) -> void:
	var note := text.strip_edges()
	if note != "":
		append_note(note)
	_close_note_box()

## Append one feedback note to Alethea-cc/state/sandbox/notes.jsonl, keyed to this scene id. Same
## JSONL substrate as Aperture card feedback so in-scene notes route the same way. Returns true on
## success. Pure enough for the headless test to call with an explicit path.
func append_note(note: String, path_override: String = "") -> bool:
	var abs := path_override if path_override != "" else _notes_abs_path()
	if abs == "":
		push_warning("[explore] could not resolve notes path")
		return false
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var line := JSON.stringify({
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"scene": SCENE_ID,
		"kind": "in_scene_feedback",
		"note": note,
	})
	var f := FileAccess.open(abs, FileAccess.READ_WRITE) if FileAccess.file_exists(abs) else FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		f = FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		push_warning("[explore] could not open notes file: %s" % abs)
		return false
	f.seek_end()
	f.store_line(line)
	f.close()
	print("[explore] note appended to %s" % abs)
	return true

## Resolve the absolute path to Alethea-cc/state/sandbox/notes.jsonl by walking up from the Godot
## project dir (…/Resonance-Evolution/godot) to the Wavelet repo root. The sandbox state dir lives in
## the Wavelet repo, so notes from either repo's tooling land in one place.
func _notes_abs_path() -> String:
	var proj := ProjectSettings.globalize_path("res://")   # …/Resonance-Evolution/godot/
	# Try the Wavelet-root layout first (…/Wavelet/Alethea-cc/state/sandbox/notes.jsonl).
	var candidates := [
		proj.path_join("../../../").simplify_path().path_join(NOTES_REL),  # …/Wavelet/
		proj.path_join("../").simplify_path().path_join("Alethea-cc/state/sandbox/notes.jsonl"),
		proj.path_join("state/sandbox/notes.jsonl"),                       # in-project fallback
	]
	for c in candidates:
		var base := (c as String).get_base_dir().get_base_dir()  # …/Alethea-cc/state
		if DirAccess.dir_exists_absolute(base) or DirAccess.dir_exists_absolute(base.get_base_dir()):
			return c
	# Nothing pre-existing: default to the Wavelet-root candidate (make_dir_recursive creates it).
	return candidates[0]

# --- CI one-shot: `-- --shot` renders a few frames → png → quit (proves it runs windowed) ---------

const SHOT_OUT := "res://live/explore_shot.png"

func _process(_delta: float) -> void:
	if "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args():
		_shot_frames += 1
		if _shot_frames == 15:
			await _capture(SHOT_OUT)
			get_tree().quit()

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://live"))
	get_viewport().get_texture().get_image().save_png(path)
