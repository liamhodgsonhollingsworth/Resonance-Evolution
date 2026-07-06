extends Node3D
## EXPLORE-A-SCENE demo (Aperture demo #17). Liam verbatim (2026-07-05, item 3):
## "explore around a premade scene that you find on the internet and load in ... go into them and
## pick up and collect assets using the sandbox grab feature and store them in my inventory ...
## walk around a scene and run into solid walls." — and (2026-07-05) Liam APPROVED all 5 candidate
## scenes, so this now VENDORS + makes explorable: KayKit Dungeon Remastered (CC0), Godot 3D
## Platformer level (MIT), Kenney Mini Dungeon (CC0), Quaternius Modular Dungeon (CC0), and a
## Sketchfab dungeon environment (CC-BY 4.0, attribution surfaced).
##
## WHAT THIS SCENE IS
##   * A first-person EXPLORER: WASD + mouselook + SOLID-WALL collision. The player is the in-house
##     FpsController (a CharacterBody3D) — reused as-is, no fork. Walls are StaticBody3D + a collider,
##     so you actually RUN INTO them (move_and_slide stops the body); you cannot pass through.
##   * ANY of the 5 vendored scenes, chosen by a scene=<slug> launch param (from the Aperture card),
##     OR a SCENE SELECTOR menu when no scene is given (click a scene, it opens in this window). Each
##     scene is either a pre-assembled GLB (auto-wrapped in trimesh colliders so it is solid) or a
##     KIT of pieces the explorer lays out as a walled room + scattered props. See explore_scenes.gd.
##   * COLLECTIBLES scattered in the scene. Each is a real scene Node3D built from a renderer-neutral
##     scene_node descriptor (the same DATA the renderer + inventory speak), registered as a walk-up
##     pickable through ExploreGrabAdapter — the sandbox GRAB + INVENTORY feature, imported READ-ONLY
##     from the peer lane (walkabout/pickup_interactor.gd). Walk up, press E, it is in your inventory.
##   * PROCEDURAL FALLBACK: if a chosen scene's assets are missing (download failed), the explorer
##     builds a portable walled room dressed with the imported Kenney/Quaternius CC0 props, so the
##     demo NEVER hard-fails.
##   * IN-SCENE FEEDBACK: press F1 to open a note box; what you type is appended to
##     Alethea-cc/state/sandbox/notes.jsonl keyed to this scene id — the SAME feedback substrate as
##     Aperture card feedback.
##
## LAUNCH (windowed, walkable):
##   <godot> --path godot res://examples/explore/explore_scene_demo.tscn                       # selector
##   <godot> --path godot res://examples/explore/explore_scene_demo.tscn -- --scene-params={"scene":"kaykit_dungeon"}
## HEADLESS smoke test:
##   <godot> --headless --path godot -s res://headless_explore_test.gd

const GrabAdapter := preload("res://examples/explore/explore_grab_adapter.gd")
const Scenes := preload("res://examples/explore/explore_scenes.gd")
const FpsControllerScript := preload("res://walkabout/fps_controller.gd")
const RendererScript := preload("res://renderers/godot_scene_renderer.gd")

const SCENE_ID := "explore_scene_demo"
const NOTES_REL := "Alethea-cc/state/sandbox/notes.jsonl"   # relative to the Wavelet repo root

## Room geometry (the procedural fallback + the assembled-kit room): a square walled room.
const ROOM_HALF := 12.0     # half the interior extent (meters) — room is 24m square
const WALL_HEIGHT := 4.0
const WALL_THICK := 0.5
const PICKUP_RADIUS := 2.5  # walk within this many meters to grab (matches the sandbox default)

var _slug := ""              # the chosen scene slug ("" -> selector, unless a param/const forces one)
var _player: CharacterBody3D
var _grab: ExploreGrabAdapter
var _feedback: CanvasLayer
var _selector: CanvasLayer
var _shot_frames := 0

func _ready() -> void:
	_slug = _requested_slug()
	if _slug == "":
		# No scene chosen -> show the selector. (Skipped under --shot so CI captures a real scene.)
		if _shot_mode():
			_slug = Scenes.order()[0]
		else:
			_add_lighting()
			_build_selector()
			return
	_enter_scene(_slug)

## Build the whole explorable world for slug: environment + player + grab + collectibles + feedback.
func _enter_scene(slug: String) -> void:
	_build_environment(slug)
	_build_player()
	_place_player_clear()
	_grab = GrabAdapter.new()
	_grab.name = "Grab"
	add_child(_grab)
	_grab.setup(self, _player, self)
	_scatter_collectibles(slug)
	_build_feedback_ui(slug)
	print("[explore] ready; scene=%s; %d collectible(s); player at %s" % [
		slug if slug != "" else "procedural_room", _grab.pickable_count(), str(_player.global_position)])

## The requested scene slug: the scene key of --scene-params=<json>, else "" (-> selector).
func _requested_slug() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene-params="):
			var parsed = JSON.parse_string(a.substr("--scene-params=".length()))
			if typeof(parsed) == TYPE_DICTIONARY and parsed.has("scene"):
				return String(parsed["scene"]).strip_edges()
	return ""

# --- ENVIRONMENT ---------------------------------------------------------------------------------

func _build_environment(slug: String) -> void:
	_add_lighting()
	_add_floor()
	var reg := Scenes.registry()
	if slug != "" and reg.has(slug) and Scenes.is_vendored(slug):
		var cfg: Dictionary = reg[slug]
		var kind := String(cfg.get("kind", "assembled"))
		if kind == "glb" and _build_glb_scene(slug, cfg):
			return
		if kind == "assembled" and _build_assembled_scene(slug, cfg):
			return
	# Missing assets / unknown slug / build failed -> the portable walled-room fallback.
	_build_walled_room()

## KIND "glb": load the single pre-assembled GLB and wrap its meshes in trimesh colliders (solid).
func _build_glb_scene(slug: String, cfg: Dictionary) -> bool:
	var glb := Scenes.glb_dir(slug) + String(cfg.get("glb", "scene.glb"))
	var abs := ProjectSettings.globalize_path(glb)
	if not FileAccess.file_exists(abs):
		# The configured filename may differ; take the first glb present.
		var names: Array = Scenes.glb_names(slug)
		if names.is_empty():
			return false
		glb = Scenes.glb_dir(slug) + String(names[0]) + ".glb"
		abs = ProjectSettings.globalize_path(glb)
		if not FileAccess.file_exists(abs):
			return false
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(abs, state) != OK:
		push_warning("[explore] failed to load premade scene: %s" % glb)
		return false
	var scene := doc.generate_scene(state)
	if scene == null:
		return false
	var env := Node3D.new()
	env.name = "PremadeScene"
	env.add_child(scene)
	add_child(env)
	_add_static_colliders(env)
	return true

## KIND "assembled": lay out a walled dungeon room from the kit's structure pieces (walls to run
## into) and keep the walled-room's own solid boundary so you can never leave the play space. The
## kit's PROP pieces are scattered by _scatter_collectibles (grab targets). Structure pieces are
## placed as decorated SOLID colliders on the room perimeter + interior.
func _build_assembled_scene(slug: String, cfg: Dictionary) -> bool:
	var names: Array = Scenes.glb_names(slug)
	if names.is_empty():
		return false
	# Always keep the solid boundary walls (guarantees "run into solid walls" regardless of what the
	# kit contains), then DRESS the interior with the kit's structure GLBs so it reads as a dungeon.
	_build_walled_room()
	var struct_hints: Array = cfg.get("structure_hints", [])
	var struct_names := _match_names(names, struct_hints)
	if struct_names.is_empty():
		return true  # boundary room is enough; props still scatter
	var dir := Scenes.glb_dir(slug)
	# Line the interior perimeter + a few interior clusters with structure pieces (decor + solid).
	var spots := [
		Vector3(-8, 0, -8), Vector3(0, 0, -9), Vector3(8, 0, -8),
		Vector3(-9, 0, 0), Vector3(9, 0, 0),
		Vector3(-8, 0, 8), Vector3(0, 0, 9), Vector3(8, 0, 8),
		Vector3(-3, 0, -3), Vector3(3, 0, 3), Vector3(-3, 0, 3), Vector3(3, 0, -3),
	]
	var i := 0
	for pos in spots:
		var base := String(struct_names[i % struct_names.size()])
		var desc := { "name": base, "mesh": { "source": "glb", "path": dir + base + ".glb" } }
		var node: Node3D = RendererScript.build_node(desc)
		if node == null:
			i += 1
			continue
		node.name = "structure_%d" % i
		add_child(node)
		node.global_position = pos
		node.rotation_degrees = Vector3(0, (i * 45) % 360, 0)
		_add_static_colliders(node)   # make the placed structure solid too
		i += 1
	return true

## Walk a subtree's meshes and give each a trimesh StaticBody3D collider, so arbitrary GLB geometry
## becomes solid without hand-authoring collision.
func _add_static_colliders(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			(n as MeshInstance3D).create_trimesh_collision()
		for c in n.get_children():
			stack.append(c)

## The portable fallback environment / the assembled-room boundary: four SOLID walls forming a room.
func _build_walled_room() -> void:
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.42, 0.40, 0.46)
	var span := ROOM_HALF * 2.0 + WALL_THICK
	_add_wall(Vector3(0, WALL_HEIGHT * 0.5, -ROOM_HALF - WALL_THICK * 0.5), Vector3(span, WALL_HEIGHT, WALL_THICK), wall_mat, "WallN")
	_add_wall(Vector3(0, WALL_HEIGHT * 0.5,  ROOM_HALF + WALL_THICK * 0.5), Vector3(span, WALL_HEIGHT, WALL_THICK), wall_mat, "WallS")
	_add_wall(Vector3(-ROOM_HALF - WALL_THICK * 0.5, WALL_HEIGHT * 0.5, 0), Vector3(WALL_THICK, WALL_HEIGHT, span), wall_mat, "WallW")
	_add_wall(Vector3( ROOM_HALF + WALL_THICK * 0.5, WALL_HEIGHT * 0.5, 0), Vector3(WALL_THICK, WALL_HEIGHT, span), wall_mat, "WallE")

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
	plane.size = Vector2(ROOM_HALF * 6.0, ROOM_HALF * 6.0)   # generous so GLB scenes sit on a floor
	mi.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.18, 0.20, 0.24)
	mi.material_override = mat
	floor_body.add_child(mi)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(ROOM_HALF * 6.0, 0.2, ROOM_HALF * 6.0)
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

# --- PLAYER --------------------------------------------------------------------------------------

func _build_player() -> void:
	var player: CharacterBody3D = FpsControllerScript.new()
	player.name = "Player"
	player.position = Vector3(0, 1.5, 0)   # provisional; _place_player_clear() moves it to a verified-clear spot
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
	cam.far = 500.0
	player.add_child(cam)
	add_child(player)
	_player = player

## Move the player to a spot that is CLEAR of solid geometry (Liam 2026-07-05 defect: "in this dungeon
## I can't move around at all" - the fixed corner spawn landed inside a placed wall piece for KayKit).
## Tries a ring of candidate points; for each it (a) requires the capsule not to overlap any static
## body and (b) snaps the player onto the floor via a downward ray. Falls back to the room centre.
func _place_player_clear() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	# Let physics register the just-added static colliders before we query the space (a direct-space
	# query right after add_child can miss brand-new bodies). Two physics frames is ample + headless-safe.
	if get_tree() != null:
		await get_tree().physics_frame
		await get_tree().physics_frame
	if not is_instance_valid(_player):
		return
	var space := _player.get_world_3d().direct_space_state if _player.get_world_3d() != null else null
	var candidates := [
		Vector3(0, 1.5, 0),
		Vector3(4, 1.5, 4), Vector3(-4, 1.5, -4), Vector3(4, 1.5, -4), Vector3(-4, 1.5, 4),
		Vector3(0, 1.5, 6), Vector3(6, 1.5, 0), Vector3(0, 1.5, -6), Vector3(-6, 1.5, 0),
		Vector3(ROOM_HALF - 5.0, 1.5, ROOM_HALF - 5.0),
	]
	for c in candidates:
		var spot := _clear_spot(space, c)
		if spot != Vector3.INF:
			_player.global_position = spot
			return
	# Nothing verified clear (headless without physics, or an unusually dense scene): centre is safest.
	_player.global_position = Vector3(0, 1.5, 0)

## If `cand` is clear (no static body overlaps the player capsule there), return it snapped to the
## floor; else Vector3.INF. Headless-with-no-space returns the candidate as-is (best effort).
func _clear_spot(space, cand: Vector3) -> Vector3:
	if space == null:
		return cand
	# Snap onto the ground first (ray down), so we test the capsule where the body will actually rest.
	var down := PhysicsRayQueryParameters3D.create(cand + Vector3(0, 4, 0), cand + Vector3(0, -8, 0))
	var hit: Dictionary = space.intersect_ray(down)
	var base := cand
	if not hit.is_empty():
		base = Vector3(cand.x, float(hit["position"].y) + 1.0, cand.z)
	# Capsule-overlap test at the resting spot (capsule offset +0.9, height 1.8, radius 0.35).
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	q.shape = cap
	q.transform = Transform3D(Basis(), base + Vector3(0, 0.9, 0))
	q.collision_mask = 0xFFFFFFFF
	q.exclude = [_player.get_rid()]
	var overlaps: Array = space.intersect_shape(q, 4)
	if overlaps.is_empty():
		return base
	return Vector3.INF

# --- COLLECTIBLES --------------------------------------------------------------------------------

func _scatter_collectibles(slug: String) -> void:
	var picks := _collectible_descriptors(slug)
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

## Collectibles for slug: prefer the scene's OWN prop GLBs (assembled kits carry props); for GLB
## scenes (platformer/sketchfab) use the imported manifest kits. Primitive gem fallback so the loop
## is never empty.
func _collectible_descriptors(slug: String) -> Array:
	var out: Array = []
	var positions := [
		Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-6, 0, 6),
		Vector3(0, 0, -8), Vector3(-8, 0, 0), Vector3(0, 0, 0),
		Vector3(-3, 0, 2), Vector3(2, 0, -3),
	]
	var prop_descs := _scene_prop_descriptors(slug, positions.size())
	for j in positions.size():
		var desc: Dictionary
		if j < prop_descs.size():
			desc = prop_descs[j]
		else:
			desc = { "name": "gem", "mesh": { "source": "primitive", "shape": "sphere", "params": { "radius": 0.4 } } }
		out.append({ "desc": desc, "pos": positions[j] })
	return out

## Up to limit prop descriptors for the scene: the scene's own kit props if it is an assembled kit
## with matching prop GLBs, else the imported manifest kits, else empty (-> primitive gems).
func _scene_prop_descriptors(slug: String, limit: int) -> Array:
	var out: Array = []
	var reg := Scenes.registry()
	if slug != "" and reg.has(slug) and Scenes.is_vendored(slug):
		var cfg: Dictionary = reg[slug]
		if String(cfg.get("kind", "")) == "assembled":
			var names: Array = Scenes.glb_names(slug)
			var prop_names := _match_names(names, cfg.get("prop_hints", []))
			var dir := Scenes.glb_dir(slug)
			for base in prop_names:
				if out.size() >= limit:
					break
				out.append({ "name": String(base), "mesh": { "source": "glb", "path": dir + String(base) + ".glb" } })
			if not out.is_empty():
				return out
	# GLB scenes (or an assembled kit with no matched props): fall back to the imported manifest kits.
	for p in _manifest_collectible_paths(limit):
		out.append({ "name": p["name"], "mesh": { "source": "glb", "path": p["path"] } })
	return out

## Basenames whose lowercase contains ANY of the hint substrings, in kit order.
func _match_names(names: Array, hints: Array) -> Array:
	var out: Array = []
	for n in names:
		var low := String(n).to_lower()
		for h in hints:
			if low.contains(String(h).to_lower()):
				out.append(n)
				break
	return out

## Read up to limit GLB collectible paths from the imported asset manifest (Kenney/Quaternius CC0).
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
		if nm.contains("_-_free_model"):
			nm = nm.split("_-_free_model")[0]
		out.append({ "name": nm, "path": String(a.get("path", "")) })
	return out

# --- SCENE SELECTOR: no scene param -> a menu of the 5 vendored scenes -----------------------------

func _build_selector() -> void:
	_selector = CanvasLayer.new()
	_selector.name = "SelectorLayer"
	_selector.layer = 30
	add_child(_selector)
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(520, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.10, 0.96)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Choose a scene to explore"
	title.add_theme_color_override("font_color", Color(0.72, 0.85, 0.98))
	title.add_theme_font_size_override("font_size", 20)
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Pick a scene to walk around in."
	sub.add_theme_color_override("font_color", Color(0.6, 0.66, 0.74))
	sub.add_theme_font_size_override("font_size", 12)
	vb.add_child(sub)
	for slug in Scenes.order():
		var cfg: Dictionary = Scenes.registry()[slug]
		var vendored := Scenes.is_vendored(slug)
		var btn := Button.new()
		var lic := String(cfg.get("license", ""))
		btn.text = "%s   [%s]%s" % [String(cfg.get("title", slug)), lic, "" if vendored else "   (fallback room)"]
		btn.tooltip_text = slug
		btn.custom_minimum_size = Vector2(480, 40)
		btn.pressed.connect(_on_scene_chosen.bind(slug))
		vb.add_child(btn)
	_selector.add_child(panel)

## Chosen from the selector: tear the menu down and enter that scene IN THIS window.
func _on_scene_chosen(slug: String) -> void:
	if _selector != null:
		_selector.queue_free()
		_selector = null
	_slug = slug
	_enter_scene(slug)

# --- IN-SCENE FEEDBACK ---------------------------------------------------------------------------

func _build_feedback_ui(slug: String) -> void:
	_feedback = CanvasLayer.new()
	_feedback.name = "FeedbackLayer"
	_feedback.layer = 20
	add_child(_feedback)
	# (No controls-explanation text - Liam 2026-07-05. F1 for a note is global + intuitive; the
	# CC-BY attribution below is a legal credit, not a controls hint, so it stays.)
	# CC-BY attribution surfaced bottom-right in-scene (empty for CC0/MIT).
	var att := Scenes.attribution_line(slug)
	if att != "":
		var att_label := Label.new()
		att_label.text = att
		att_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
		att_label.add_theme_font_size_override("font_size", 11)
		att_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		att_label.position += Vector2(-420, -28)
		_feedback.add_child(att_label)
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
	title.text = "Note about this scene (Enter to send - Esc to cancel)"
	title.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	vb.add_child(title)
	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "what works / what to change..."
	_note_edit.custom_minimum_size = Vector2(430, 0)
	_note_edit.text_submitted.connect(_on_note_submitted)
	vb.add_child(_note_edit)
	_feedback.add_child(_note_panel)

var _note_panel: PanelContainer
var _note_edit: LineEdit

func _unhandled_input(event: InputEvent) -> void:
	# F1 is now owned by the GLOBAL GizmoNote autoload (works in EVERY scene) -- no per-scene F1 here.
	# The ESC branch below still closes this scene's own note box if some other affordance opened it.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and _note_panel != null and _note_panel.visible:
			_close_note_box()

func _toggle_note_box() -> void:
	if _note_panel == null:
		return
	if _note_panel.visible:
		_close_note_box()
		return
	_note_panel.visible = true
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

## Append one feedback note to Alethea-cc/state/sandbox/notes.jsonl, keyed to this scene id.
func append_note(note: String, path_override: String = "") -> bool:
	var abs := path_override if path_override != "" else _notes_abs_path()
	if abs == "":
		push_warning("[explore] could not resolve notes path")
		return false
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var line := JSON.stringify({
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"scene": SCENE_ID,
		"subscene": _slug,
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

func _notes_abs_path() -> String:
	var proj := ProjectSettings.globalize_path("res://")
	var candidates := [
		proj.path_join("../../../").simplify_path().path_join(NOTES_REL),
		proj.path_join("../").simplify_path().path_join("Alethea-cc/state/sandbox/notes.jsonl"),
		proj.path_join("state/sandbox/notes.jsonl"),
	]
	for c in candidates:
		var base := (c as String).get_base_dir().get_base_dir()
		if DirAccess.dir_exists_absolute(base) or DirAccess.dir_exists_absolute(base.get_base_dir()):
			return c
	return candidates[0]

# --- CI one-shot: -- --shot renders a few frames -> png -> quit -----------------------------------

const SHOT_OUT := "res://live/explore_shot.png"

func _shot_mode() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _process(_delta: float) -> void:
	if _shot_mode():
		_shot_frames += 1
		if _shot_frames == 15:
			await _capture(SHOT_OUT)
			get_tree().quit()

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://live"))
	get_viewport().get_texture().get_image().save_png(path)
