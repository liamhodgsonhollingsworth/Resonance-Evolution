extends Node3D
## THE 3D APERTURE — a SANDBOX-FEATURED ROOM (Liam spec 2026-07-05 items 4 & 5). This SUPERSEDES the
## old card-gallery aperture_3d (git history preserves it). The 3D aperture is now a walkable room you
## re-arrange with the latest sandbox features, with NONE of the old in-world 2D menu pages / art links.
##
## VERBATIM (item 4): "For the 3D aperture, this should be a scene which has all the most recent and up
## to date features to do with the sandbox environment (picking up and removing nodes) so that I can
## change the layout of this area. The 3D aperture will have none of the same 2D menu pages or links to
## things like art, but instead should have a 3D computer asset that I can interact with by right
## clicking when holding nothing and opening it opens the 2D page (which I leave using escape). Then,
## when you want to show me a new scene or area that I can go to, you both either place it in the 2D
## aperture page as a clickable card, or you put a physical door or gateway in the world that I can
## enter to go into the scene (and to leave is wired to escape for now)."
##
## WHAT IS IN THE ROOM:
##   * A first-person player (WASD + mouse-look, gravity-free fly toggle) inside a bounded room whose
##     WALLS ARE SOLID (you cannot walk out - the "run into solid walls" feel).
##   * SANDBOX FEATURES, composed from the merged runtime helpers (NOT a fork of sandbox_creative.gd -
##     a peer lane refactors that; see the design note for what clean controller reuse would need):
##       - PLACE a node from the hotbar: aim + place ANYWHERE the ray hits (FREE placement - NO grid
##         snapping, NO highlighted preview marker; spec item 2). Empty-handed left-click picks up a
##         placed node.
##       - PICK UP / MOVE a node: aimed node follows the ray; click to drop it (rearrange the layout).
##       - REMOVE a node: X deletes the aimed/held node ("removing nodes").
##       - DROP the held hotbar item: Q - it simply disappears for now (spec item 1: "for now they can
##         simply disappear instead of physically resting on the ground").
##       - EMPTY HAND: hotbar slot 0 holds nothing; with an empty hand LEFT-click picks up / RIGHT-click
##         on the computer opens the 2D board (spec item 1 + item 4).
##       - Layout PERSISTS as an append-only world in the world store (F5 saves v(N+1)).
##   * A 3D COMPUTER (computer_terminal.gd): right-click it EMPTY-HANDED -> the 2D aperture board mounts
##     as a same-window overlay; ESC returns to the room.
##   * PHYSICAL DOORS (door_gateway.gd): walk into one to enter its target scene via SceneTransition
##     (same window for stable scenes, a new godot window for experimental ones); ESC leaves.
##   * IN-SCENE FEEDBACK: press F -> a note box -> appended to Alethea-cc/state/sandbox/notes.jsonl keyed
##     to scene id "aperture_3d" (the SAME substrate as card feedback; overarching spec ask).
##
## Open live:   <Godot> --path godot res://aperture/aperture_3d.tscn
## Proof PNG:   <Godot> --path godot res://aperture/aperture_3d.tscn -- --shot
## (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe for stdout.)

const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")
const AssetLibraryScript := preload("res://runtime/asset_library.gd")
const WorldStoreScript := preload("res://runtime/world_store.gd")
const Behaviors := preload("res://runtime/sandbox_behaviors.gd")
const SceneTransition := preload("res://aperture/scene_transition.gd")
const DoorGateway := preload("res://aperture/door_gateway.gd")
const ComputerTerminal := preload("res://aperture/computer_terminal.gd")
const InputGate := preload("res://walkabout/input_gate.gd")
const GraphPanelMount := preload("res://aperture/graph_panel_mount.gd")  # thin diegetic node-panel overlay (Slice 1)
const WiringTool := preload("res://runtime/wiring_tool.gd")               # point-and-bind target resolver (Slice 1)
const PickupInteractorScript := preload("res://walkabout/pickup_interactor.gd")  # reused proximity register/refresh seam

const SCENE_ID := "aperture_3d"
const NOTES_PATH := "G:/Wavelet/Alethea-cc/state/sandbox/notes.jsonl"
const WORLD_NAME := "aperture_room"
const SHOT_PATH := "res://docs/aperture_3d.png"

# THE ROOM AS A NODE ARRANGEMENT (Liam 2026-07-06): the room shell (floor + ceiling + 4 walls),
# the always-on sky, and the fill light are all one hotloading arrangement, NOT imperative geometry.
# Edit this file while the aperture runs and the room diff-hotloads (move/resize a wall, retint the sky).
const ROOM_ARRANGEMENT_PATH := "res://aperture/aperture_room_shell.json"

const ROOM_HALF := 12.0            # room is 2*ROOM_HALF on X/Z
const ROOM_HEIGHT := 6.0
const WALL_MARGIN := 0.4           # keep the player this far off the walls (solid-wall collision)
const REACH := 9.0                 # how far the build/pick ray reaches

# -- sandbox state (composed from runtime helpers; NO grid) -----------------------------------------
var objects: Dictionary = {}       # "obj_N" -> {id, asset, base_pos, yaw_deg, scale, behaviors, node, loaded, aabb}
var _obj_seq := 0
var palette: Array = []            # hotbar entries; index 0 = EMPTY HAND (spec item 1: holding nothing)
var hotbar: Array = []
var active_slot := 0               # 0 = empty hand
var selected_id := ""              # picked-up/aimed node
var _grabbing := false             # held node follows the ray until dropped

var assets: Node = null
var store = null

# -- nodes ------------------------------------------------------------------------------------------
var _cam: Camera3D
var _objects_root: Node3D
var _doors_root: Node3D

# -- room-as-arrangement (the node-driven shell + sky + lights; diff-hotloads) ----------------------
var _room_runtime: GraphRuntime = null       # interprets aperture_room_shell.json into live primitives
var _room_renderer: GodotSceneRenderer = null # the delegate that builds the shell + env + lights
var _room_arr_mtime := -1                     # mtime of the arrangement JSON (poll for hotload)
var _hud: CanvasLayer
var _status: Label
var _hotbar_ui: HBoxContainer
var _note_panel: Panel
var _note_edit: LineEdit
var _crosshair: Control

# -- camera / movement ------------------------------------------------------------------------------
var _yaw := 0.0
var _pitch := -0.1
var fly_speed := 6.0
var sprint_mult := 2.5
var mouse_sens := 0.0025
var _pos := Vector3(0.0, 1.7, 8.0)  # player position (integrated so wall collision is trivial)

# -- interaction state ------------------------------------------------------------------------------
var _aimed_meta := {}              # meta of the Area3D under the crosshair this frame
# WIRING TOOL (Slice 1): a PickupInteractor gives the "point at / walk up to an object" proximity seam
# (register/refresh/available_ids), reused verbatim; the aim seam (_aimed_meta.obj_id) is the primary
# target. Binding an object opens its node graph in a GraphPanel overlay that live-writes + hot-loads.
var _wiring_interactor: PickupInteractor = null   # registers placed objects for the proximity fallback
var _note_open := false
var _did_shot := false
var _headless := false
var _time := 0.0
var _time_since_arr_poll := 0.0    # throttles the room-arrangement mtime poll (hotload)
var _doors: Array = []             # DoorGateway instances (polled for walk-in)

# The doors to place in the room. DATA - each is a SceneTransition target + placement. Adding a portal
# for a new explorable scene is ONE entry (its res:// scene + same_window flag + placement). Every door
# below points at a scene that ACTUALLY EXISTS on origin/main and was walk-through-verified live (Liam
# 2026-07-05 defect fixes 3/4/5): the prior specs pointed at a non-existent aperture_explore_scene.tscn
# (dungeon door dead) and had NO gallery door at all. All three are SAME-WINDOW: the self-cleaning
# TransitionOverlay (scene_transition.gd) makes each seamless AND leaveable with ESC back to the room,
# with no edit to the read-only destination scenes.
var door_specs: Array = [
	{
		# HOME AREA (Liam 2026-07-06, room-series slice 1): a NEW sandbox-editable HOME room reached by
		# walking through THIS door. Distinct scene (aperture/sandbox_home.tscn) that reuses the creative
		# sandbox's full editing (place/move/rotate + palette + Manipulation Wand) and adds SKY + CLOUDS.
		# Same-window + seamless; ESC returns to this room (the self-cleaning overlay wires leave = ESC).
		"scene": "res://aperture/sandbox_home.tscn",
		"same_window": true,
		"label": "Home",
		"color": [0.75, 0.95, 0.78],
		"position": [11.4, 0.0, 0.0], "yaw_deg": -90.0,
	},
	{
		# DUNGEONS (defect #3: portals were missing). The real vendored explorer (RE #155): with no
		# scene param it opens the SCENE SELECTOR menu; pick a dungeon and it loads in this window.
		"scene": "res://examples/explore/explore_scene_demo.tscn",
		"same_window": true,
		"label": "Dungeons",
		"color": [0.95, 0.78, 0.5],
		"position": [-7.0, 0.0, -11.4], "yaw_deg": 0.0,
	},
	{
		# GALLERY (defect #4: gateway did nothing - there was no gallery door). The turntable showcase
		# scene; ESC returns to the room via the overlay (gallery.gd is read-only, so leave is ours).
		"scene": "res://gallery/gallery.tscn",
		"same_window": true,
		"label": "Gallery",
		"color": [0.55, 0.8, 1.0],
		"position": [-11.4, 0.0, 0.0], "yaw_deg": 90.0,
	},
	{
		# SANDBOX (defect #5: same-window swap left a stuck black cover). Fixed by the self-cleaning
		# overlay; the sandbox now opens interactive (its own camera/HUD/mouse) and ESC returns.
		"scene": "res://examples/sandbox_creative.tscn",
		"same_window": true,
		"label": "Sandbox",
		"color": [0.7, 0.95, 0.7],
		"position": [7.0, 0.0, -11.4], "yaw_deg": 0.0,
	},
]


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# Complete a seamless same-window ENTER, if we arrived through a transition (item 5).
	SceneTransition.fade_in_on_ready(self)
	_build_room()
	_build_camera()
	_build_computer()
	_build_doors()
	_build_palette()
	assets = AssetLibraryScript.new()
	assets.name = "AssetLibrary"
	add_child(assets)
	assets.load_manifest()
	assets.asset_ready.connect(_on_asset_ready)
	_extend_palette_with_assets()
	store = WorldStoreScript.new()
	store.seed_from()
	_load_room_layout()
	_build_wiring_interactor()   # Slice 1: proximity seam for point-and-bind (registers loaded objects)
	if not _headless:
		_build_hud()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_camera_rotation()
	if _shot_home_door_requested():
		await _take_home_door_shot()
	elif _shot_board_requested():
		await _take_board_shot()
	elif _shot_requested():
		await _take_shot()


func _process(delta: float) -> void:
	_time += delta
	_tick_objects(delta)
	# HOTLOAD the room arrangement: if aperture_room_shell.json changed on disk, re-load + diff-render
	# the shell/sky/lights in place (the runtime keeps unchanged primitives; only edited nodes update).
	# Polled every ~0.4s so an edit-and-save updates the LIVE room without a restart. Skips in a --shot
	# run (nothing to hotload) and is cheap when the mtime is unchanged.
	if not _did_shot:
		_time_since_arr_poll += delta
		if _time_since_arr_poll >= 0.4:
			_time_since_arr_poll = 0.0
			var m := _room_arr_file_mtime()
			if m != _room_arr_mtime:
				_reload_room_arrangement()
	if _headless or _did_shot:
		return
	_update_movement(delta)
	_update_aim()
	_poll_doors()


# == ROOM (bounded, solid walls) ===================================================================

func _build_room() -> void:
	# THE ROOM IS A NODE ARRANGEMENT (Liam 2026-07-06): the floor + ceiling + 4 solid walls, the
	# always-on sky, and the fill light are ONE arrangement (aperture_room_shell.json) the GraphRuntime
	# interprets into live primitives and the GodotSceneRenderer delegate builds — exactly the
	# load_arrangement -> evaluate -> render pattern lsystem_scene uses. Editing that JSON while the
	# aperture runs diff-hotloads the room (see _reload_room_arrangement, polled in _process). We build
	# geometry (render), sky (apply_environment), and lights (apply_lights) from the SAME evaluate().
	#
	# The room renderer mounts into a dedicated child so its shell instances / env / lights sit in a
	# stable subtree and never collide with the player camera (no View node in the arrangement — the
	# first-person _cam below stays authoritative), the placed objects, or the doors.
	var room_root := Node3D.new()
	room_root.name = "RoomShell"
	add_child(room_root)
	_room_runtime = GraphRuntime.new()
	add_child(_room_runtime)
	_room_renderer = GodotSceneRenderer.new()
	room_root.add_child(_room_renderer)
	_reload_room_arrangement()

	_objects_root = Node3D.new()
	_objects_root.name = "Objects"
	add_child(_objects_root)
	_doors_root = Node3D.new()
	_doors_root.name = "Doors"
	add_child(_doors_root)


## Load (or hotload) the room arrangement: parse the JSON, DIFF it into the runtime (kept primitives
## are updated in place, not rebuilt), evaluate the dataflow, then build the shell geometry + sky +
## lights from the one evaluate() output. Called once at build and again whenever the JSON mtime
## changes. Fail-open: a missing / malformed arrangement leaves the last-good room standing.
func _reload_room_arrangement() -> void:
	if _room_runtime == null or _room_renderer == null:
		return
	var data = _load_room_arrangement_data()
	if typeof(data) != TYPE_DICTIONARY or (data as Dictionary).is_empty():
		return
	_room_runtime.load_arrangement(data)
	var eval_output := _room_runtime.evaluate()
	# Geometry (shell boxes) — the terminal Group descriptor becomes the live Node3D tree.
	_room_renderer.render(eval_output, _room_runtime.arrangement)
	# Sky + sun (mount on this scene so ambient/reflections light the whole room, not just the subtree).
	_room_renderer.apply_environment(eval_output, _room_runtime.arrangement, self)
	# Fill light(s) — mounted on this scene alongside the sky's sun.
	_room_renderer.apply_lights(eval_output, _room_runtime.arrangement, self)
	_room_arr_mtime = _room_arr_file_mtime()


func _load_room_arrangement_data():
	if not FileAccess.file_exists(ROOM_ARRANGEMENT_PATH):
		push_warning("aperture_3d: room arrangement missing: %s" % ROOM_ARRANGEMENT_PATH)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ROOM_ARRANGEMENT_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("aperture_3d: room arrangement is not valid JSON: %s" % ROOM_ARRANGEMENT_PATH)
		return {}
	return parsed


func _room_arr_file_mtime() -> int:
	var abs := ProjectSettings.globalize_path(ROOM_ARRANGEMENT_PATH)
	if not FileAccess.file_exists(ROOM_ARRANGEMENT_PATH):
		return -1
	return int(FileAccess.get_modified_time(abs))


func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.position = _pos
	add_child(_cam)
	_cam.make_current()


# == COMPUTER + DOORS ==============================================================================

func _build_computer() -> void:
	var comp := ComputerTerminal.new()
	comp.name = "Computer"
	comp.position = Vector3(0.0, 0.0, -11.0)
	add_child(comp)
	comp.open_requested.connect(_open_board)


func _build_doors() -> void:
	for spec in door_specs:
		var door := DoorGateway.new()
		door.configure(spec)
		var p = spec.get("position", [0, 0, 0])
		door.position = Vector3(p[0], p[1], p[2])
		door.rotation_degrees = Vector3(0, float(spec.get("yaw_deg", 0.0)), 0)
		_doors_root.add_child(door)
		door.entered.connect(_on_door_entered)
		_doors.append(door)


func _poll_doors() -> void:
	if ComputerTerminal.board_is_open(self) or _note_open:
		return
	for d in _doors:
		if is_instance_valid(d):
			d.poll_player(_pos)


func _on_door_entered(target: Dictionary) -> void:
	var res := SceneTransition.enter(self, target)
	_set_status("door -> %s (%s)" % [String(target.get("label", target.get("scene", "?"))),
		String(res.get("channel", res.get("result", "?")))])


func _open_board() -> void:
	if _headless:
		return
	ComputerTerminal.open_board(self)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_status("2D aperture open - ESC to return to the room")


func _close_board() -> void:
	if ComputerTerminal.close_board(self):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_set_status("back in the room")


# == INPUT =========================================================================================

func _unhandled_input(event: InputEvent) -> void:
	if _headless or _did_shot:
		return
	# Note editor owns the keyboard while open; only ESC cancels.
	if _note_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_note(false)
		return
	# ESC priority: close the board overlay first, else release the mouse.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if GraphPanelMount.panel_is_open(self):
			_close_wiring_panel()   # Slice 1: ESC closes the node panel first (edits already live)
		elif ComputerTerminal.board_is_open(self):
			_close_board()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	# While the node panel overlay is up, the GraphPanel owns input (drag-to-rewire); only ESC (above) acts.
	if GraphPanelMount.panel_is_open(self):
		return
	# While the board overlay is up, the 2D board owns input (its own scene handles clicks/keys).
	if ComputerTerminal.board_is_open(self):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sens
		_pitch = clampf(_pitch - event.relative.y * mouse_sens, -1.5, 1.5)
		_apply_camera_rotation()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			# F opens this room's own richer position-tagged note. F1 (any scene) opens the GLOBAL
			# GizmoNote box (autoload/gizmo_note.gd) -- different key, no conflict; both work here.
			KEY_F:
				_open_note()
				return
			KEY_Q:
				_drop_held_item()
				return
			KEY_X:
				_delete_aimed_or_selected()
				return
			KEY_R:
				_rotate_selected(-15.0 if event.shift_pressed else 15.0)
				return
			KEY_EQUAL, KEY_KP_ADD:
				_scale_selected(1.1)
				return
			KEY_MINUS, KEY_KP_SUBTRACT:
				_scale_selected(1.0 / 1.1)
				return
			KEY_F5:
				_save_room()
				return
		if event.keycode >= KEY_0 and event.keycode <= KEY_9:
			_select_slot(event.keycode - KEY_0)
			return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED    # click to recapture after ESC
				elif _grabbing:
					_drop_grabbed()                                  # click drops a held node
				else:
					_left_click()
			MOUSE_BUTTON_RIGHT:
				_right_click()
			MOUSE_BUTTON_WHEEL_UP:
				_select_slot(wrapi(active_slot - 1, 0, palette.size()))
			MOUSE_BUTTON_WHEEL_DOWN:
				_select_slot(wrapi(active_slot + 1, 0, palette.size()))


## LEFT click: EMPTY HAND -> pick up the aimed node (rearrange). Holding an item -> place it FREELY at
## the aim point (no grid, no preview). (Spec items 1 + 2.)
func _left_click() -> void:
	# WIRING tool (Slice 1): left-click also binds the pointed-at/nearby object (a tool is never placed).
	if _is_wiring_tool():
		_bind_wiring_target()
		return
	if _is_empty_hand():
		_pick_up_aimed()
		return
	_place_active()


## RIGHT click: EMPTY HAND on the computer -> open the 2D board (spec item 4). Empty hand elsewhere ->
## remove the aimed node. Holding an item does nothing special on right-click (place is left-click).
func _right_click() -> void:
	# WIRING tool (Slice 1): equipped + pointing at (or standing near) an object -> open its node panel.
	if _is_wiring_tool():
		_bind_wiring_target()
		return
	if _is_empty_hand() and String(_aimed_meta.get("interactable", "")) == "computer":
		_open_board()
		return
	if _is_empty_hand():
		_delete_aimed_or_selected()


# == HOTBAR / PALETTE (index 0 = empty hand) =======================================================

func _build_palette() -> void:
	# Slot 0 is the EMPTY HAND (holding nothing). The rest are generic building-block primitives.
	palette = [
		{ "kind": "empty", "name": "(empty hand)" },
		_pal("Cube",   "box",      {"width":1.0,"height":1.0,"depth":1.0}, [0.80,0.80,0.82]),
		_pal("Slab",   "box",      {"width":1.0,"height":0.5,"depth":1.0}, [0.66,0.70,0.74]),
		_pal("Pillar", "cylinder", {"radius":0.4,"height":1.2},           [0.78,0.72,0.60]),
		_pal("Ball",   "sphere",   {"radius":0.5},                        [0.62,0.72,0.82]),
		_pal("Cone",   "cone",     {"radius":0.5,"height":1.0},           [0.82,0.68,0.56]),
		_pal("Wedge",  "wedge",    {"width":1.0,"height":1.0,"depth":1.0},[0.66,0.78,0.64]),
		# WIRING tool (Slice 1): equip it, aim at a placed node, right-click -> its node panel opens in-world.
		# kind:"tool" so place/remove code skips it (a tool ACTS, it is not placed) — same idiom as the
		# sandbox held-item seam. A cool violet so it reads distinctly in the hotbar.
		{ "kind": "tool", "tool": "wiring", "name": "Wiring", "shape": "", "params": {},
			"material": { "albedo": [0.62, 0.55, 0.95] } },
	]
	hotbar = []
	for i in min(10, palette.size()):
		hotbar.append(i)


func _pal(name: String, shape: String, params: Dictionary, albedo: Array) -> Dictionary:
	return { "kind": "block", "name": name, "shape": shape, "params": params,
		"material": { "albedo": albedo } }


## Append a few imported assets so the room can hold real models too (metadata only; lazy-loaded).
func _extend_palette_with_assets() -> void:
	if assets == null:
		return
	var added := 0
	for kit in assets.kits:
		for a in assets.kit_assets(String(kit)):
			palette.append({ "kind": "asset", "name": String(a.get("name", a["id"])),
				"asset_id": String(a["id"]), "material": { "albedo": [0.6, 0.7, 0.6] } })
			added += 1
			if added >= 3:      # keep the room hotbar small; the sandbox scene has the full asset grid
				return


func _is_empty_hand() -> bool:
	var e: Dictionary = palette[hotbar[active_slot]] if active_slot < hotbar.size() else {}
	return String(e.get("kind", "empty")) == "empty"


func _select_slot(i: int) -> void:
	if i < 0 or i >= hotbar.size():
		return
	active_slot = i
	_rebuild_hotbar_ui()
	_set_status("slot %d" % i)


# == FREE PLACEMENT / PICK-UP / REMOVE (no grid, no preview - spec item 2) ==========================

## A ray from the camera center; returns the first hit point on room geometry / a placed object, or a
## point at REACH if nothing. FREE placement: the object lands exactly where the ray hits (no snap).
func _ray_point() -> Vector3:
	var from := _cam.global_position
	var dir := -_cam.global_transform.basis.z
	if _headless:
		return from + dir * (REACH * 0.6)
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * REACH)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.has("position"):
		return hit["position"]
	return from + dir * (REACH * 0.6)


func _place_active() -> void:
	var entry: Dictionary = palette[hotbar[active_slot]]
	if String(entry.get("kind", "")) == "tool":
		return   # tools ACT (bind), they are not placed
	var pos := _ray_point()
	pos.y = maxf(pos.y, 0.0)
	if String(entry.get("kind", "")) == "asset":
		_place_object(String(entry["asset_id"]), pos)
	else:
		_place_block(entry, pos)
	_set_status("placed %s" % String(entry.get("name", "?")))


## A placed BLOCK is one object record wrapping a primitive mesh (reusing the sandbox object layer so
## pick-up / move / delete / behaviors / save all work uniformly). No grid; base_pos is the free point.
func _place_block(entry: Dictionary, pos: Vector3) -> void:
	_obj_seq += 1
	var id := "obj_%d" % _obj_seq
	var node := Node3D.new()
	node.name = id
	_objects_root.add_child(node)
	var mi := MeshInstance3D.new()
	mi.name = "body"
	mi.mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))
	var mat := StandardMaterial3D.new()
	var albedo = entry.get("material", {}).get("albedo", [0.8, 0.8, 0.8])
	mat.albedo_color = Color(albedo[0], albedo[1], albedo[2])
	mi.material_override = mat
	node.add_child(mi)
	var aabb := mi.mesh.get_aabb() if mi.mesh != null else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	objects[id] = { "id": id, "block": entry, "asset": "", "base_pos": pos, "yaw_deg": 0.0,
		"scale": 1.0, "behaviors": [], "node": node, "loaded": true, "aabb": aabb }
	_add_pick_area(node, id, aabb)
	_register_wiring_object(id)   # Slice 1: bindable by the wiring tool


func _place_object(asset_id: String, pos: Vector3, yaw_deg := 0.0, scale := 1.0, forced_id := "") -> String:
	if assets == null or not assets.has_asset(asset_id):
		return ""
	var id := forced_id
	if id == "":
		_obj_seq += 1
		id = "obj_%d" % _obj_seq
	else:
		_obj_seq = maxi(_obj_seq, int(id.trim_prefix("obj_")))
	var node := Node3D.new()
	node.name = id
	_objects_root.add_child(node)
	var rec := { "id": id, "asset": asset_id, "block": {}, "base_pos": pos, "yaw_deg": yaw_deg,
		"scale": scale, "behaviors": [], "node": node, "loaded": false,
		"aabb": AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE) }
	objects[id] = rec
	_attach_asset_body(rec)
	return id


func _attach_asset_body(rec: Dictionary) -> void:
	var node: Node3D = rec["node"]
	var asset_id := String(rec["asset"])
	var inst: Node3D = assets.instantiate(asset_id)
	if inst != null:
		inst.name = "body"
		node.add_child(inst)
		rec["loaded"] = true
		rec["aabb"] = _combined_aabb(inst)
		_add_pick_area(node, String(rec["id"]), rec["aabb"])
		_register_wiring_object(String(rec["id"]))
	else:
		var ph := MeshInstance3D.new()
		ph.name = "body"
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.9
		ph.mesh = bm
		ph.position = Vector3(0, 0.45, 0)
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.6, 0.7, 0.9, 0.45)
		ph.material_override = m
		node.add_child(ph)
		_add_pick_area(node, String(rec["id"]), rec["aabb"])
		_register_wiring_object(String(rec["id"]))
		assets.request(asset_id)


func _on_asset_ready(asset_id: String) -> void:
	for id in objects:
		var rec: Dictionary = objects[id]
		if String(rec.get("asset", "")) == asset_id and not bool(rec["loaded"]):
			for c in (rec["node"] as Node3D).get_children():
				c.queue_free()
			_attach_asset_body(rec)


## An Area3D on the node so the crosshair ray can identify a placed node for pick-up / delete.
func _add_pick_area(node: Node3D, id: String, aabb: AABB) -> void:
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = aabb.size if aabb.size.length() > 0.01 else Vector3.ONE
	shape.shape = box
	shape.position = aabb.position + aabb.size * 0.5
	area.add_child(shape)
	area.set_meta("obj_id", id)
	node.add_child(area)


func _pick_up_aimed() -> void:
	var id := String(_aimed_meta.get("obj_id", ""))
	if id == "" or not objects.has(id):
		return
	selected_id = id
	_grabbing = true
	_set_status("picked up %s - click to drop, X to remove" % id)


func _drop_grabbed() -> void:
	_grabbing = false
	_set_status("dropped %s" % selected_id)
	selected_id = ""


func _delete_aimed_or_selected() -> void:
	var id := selected_id
	if id == "" or not objects.has(id):
		id = String(_aimed_meta.get("obj_id", ""))
	if id != "" and objects.has(id):
		_delete_object(id)
		_set_status("removed %s" % id)


func _delete_object(id: String) -> void:
	if not objects.has(id):
		return
	var rec: Dictionary = objects[id]
	var n = rec.get("node")
	if n != null and is_instance_valid(n):
		n.queue_free()
	objects.erase(id)
	if selected_id == id:
		selected_id = ""
		_grabbing = false


## Q - drop the HELD HOTBAR ITEM: it simply disappears for now (reverts to empty hand). Spec item 1.
func _drop_held_item() -> void:
	if _is_empty_hand():
		return
	_set_status("dropped held item (%s) - now empty hand" % String(palette[hotbar[active_slot]].get("name", "?")))
	_select_slot(0)


func _rotate_selected(deg: float) -> void:
	if selected_id == "" or not objects.has(selected_id):
		return
	var rec: Dictionary = objects[selected_id]
	rec["yaw_deg"] = fmod(float(rec["yaw_deg"]) + deg, 360.0)


func _scale_selected(factor: float) -> void:
	if selected_id == "" or not objects.has(selected_id):
		return
	var rec: Dictionary = objects[selected_id]
	rec["scale"] = clampf(float(rec["scale"]) * factor, 0.2, 6.0)


## Tick objects: a held node follows the ray (free point); every node applies its base transform.
func _tick_objects(delta: float) -> void:
	var ctx := { "t": _time, "delta": delta, "player_pos": _pos }
	for id in objects:
		var rec: Dictionary = objects[id]
		if _grabbing and id == selected_id and not _headless:
			var p := _ray_point()
			p.y = maxf(p.y, 0.0)
			rec["base_pos"] = p
		Behaviors.tick(rec, rec.get("node"), ctx)


func _combined_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var found := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n: Node = top[0]
		var xf: Transform3D = top[1]
		var here := xf
		if n is Node3D and n != root:
			here = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var a := here * (n as MeshInstance3D).mesh.get_aabb()
			merged = a if not found else merged.merge(a)
			found = true
		for c in n.get_children():
			stack.append([c, here])
	return merged if found else AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)


# == ROOM LAYOUT PERSISTENCE (append-only world store) =============================================

func _load_room_layout() -> void:
	if store == null:
		return
	var data: Dictionary = store.load_world(WORLD_NAME)
	if data.is_empty():
		return
	for o in data.get("objects", []):
		if typeof(o) != TYPE_DICTIONARY or not o.has("asset"):
			continue
		var p = o.get("position", [0, 0, 0])
		if typeof(p) != TYPE_ARRAY or (p as Array).size() < 3:
			continue
		if String(o["asset"]) != "":
			_place_object(String(o["asset"]), Vector3(p[0], p[1], p[2]),
				float(o.get("yaw_deg", 0.0)), float(o.get("scale", 1.0)), String(o.get("id", "")))


func _save_room() -> void:
	if store == null:
		return
	var objs := []
	for id in objects:
		var rec: Dictionary = objects[id]
		var bp: Vector3 = rec["base_pos"]
		# Only asset objects round-trip through the store today (block-primitive serialization is the
		# next follow-up); assets prove the append-only layout-persistence seam.
		if String(rec.get("asset", "")) == "":
			continue
		objs.append({ "id": id, "asset": String(rec["asset"]),
			"position": [bp.x, bp.y, bp.z], "yaw_deg": float(rec["yaw_deg"]),
			"scale": float(rec["scale"]), "behaviors": [] })
	var v: int = store.save_version(WORLD_NAME, { "objects": objs, "blocks": [] })
	_set_status("saved room layout v%d (append-only)" % v if v > 0 else "SAVE FAILED")


# == MOVEMENT (solid-wall collision by clamp) ======================================================

func _update_movement(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	# Freeze fly movement while a text field (the F note box / any LineEdit) owns focus - is_key_pressed
	# below is RAW input and would otherwise fly while typing (Liam 2026-07-05).
	if InputGate.text_input_active(get_viewport()):
		return
	var basis := _cam.global_transform.basis
	var fwd := -basis.z; fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
	var right := basis.x; right.y = 0.0
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): dir += fwd
	if Input.is_key_pressed(KEY_S): dir -= fwd
	if Input.is_key_pressed(KEY_D): dir += right
	if Input.is_key_pressed(KEY_A): dir -= right
	if Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
	if Input.is_key_pressed(KEY_SHIFT): dir += Vector3.DOWN
	if dir.length() > 0.001:
		var speed := fly_speed * (sprint_mult if Input.is_key_pressed(KEY_CTRL) else 1.0)
		_pos += dir.normalized() * speed * delta
	# SOLID WALLS: clamp inside the room (you "run into" the walls; you never pass through).
	var lim := ROOM_HALF - WALL_MARGIN
	_pos.x = clampf(_pos.x, -lim, lim)
	_pos.z = clampf(_pos.z, -lim, lim)
	_pos.y = clampf(_pos.y, 0.6, ROOM_HEIGHT - 0.4)
	_cam.position = _pos


func _apply_camera_rotation() -> void:
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.UP, _yaw)
	b = b.rotated(b.x, _pitch)
	if _cam != null:
		_cam.global_transform.basis = b


# == AIM (crosshair ray identifies the computer / a placed node) ===================================

func _update_aim() -> void:
	_aimed_meta = {}
	if _cam == null:
		return
	var from := _cam.global_position
	var to := from - _cam.global_transform.basis.z * REACH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.has("collider"):
		var col: Object = hit["collider"]
		for k in ["interactable", "obj_id"]:
			if col.has_meta(k):
				_aimed_meta[k] = col.get_meta(k)


# == WIRING TOOL: point-and-bind -> in-world node panel (Dreams-arc Slice 1) =======================
# Equip the Wiring tool, aim at (or stand near) a placed object, right-click -> its node graph opens as
# a same-window GraphPanel overlay. Every edit re-serialises to the object's arrangement file, which the
# running graph hot-loads as a diff (no scene rebuild). Two seams are reused verbatim: the room's aim
# (_aimed_meta.obj_id) and PickupInteractor's proximity register/refresh (the "walk up to it" fallback).

## Build the proximity interactor and register every currently-placed object with it, so the "nearest
## in-range object" fallback works even when the crosshair is not dead-on. Reuses PickupInteractor as-is.
func _build_wiring_interactor() -> void:
	_wiring_interactor = PickupInteractorScript.new()
	_wiring_interactor.name = "WiringInteractor"
	add_child(_wiring_interactor)
	for id in objects:
		_register_wiring_object(String(id))

## Register one object with the proximity interactor (its live node gates the "near enough to bind" test).
## Called when the interactor is built and whenever a new object is placed. Safe before the interactor
## exists (a no-op) and idempotent enough for Slice 1 (re-registering an id just adds another pickable
## for the same node; the FIRST available id wins in resolve_target, so binding stays correct).
func _register_wiring_object(id: String) -> void:
	if _wiring_interactor == null or not objects.has(id):
		return
	var rec: Dictionary = objects[id]
	var node = rec.get("node")
	if node != null and is_instance_valid(node):
		_wiring_interactor.register(id, node)

## Is the Wiring tool the active hotbar item?
func _is_wiring_tool() -> bool:
	if active_slot >= hotbar.size():
		return false
	var e: Dictionary = palette[hotbar[active_slot]]
	return String(e.get("tool", "")) == "wiring"

## The GUI bind path: resolve what the player is pointing at / near, then open its node panel. Delegates
## to bind_object(id) — the SAME backend fn the headless text verb calls (text-equivalence, gate T).
func _bind_wiring_target() -> void:
	var id := WiringTool.resolve_target(_aimed_meta, _wiring_interactor, _pos)
	if id == "":
		_set_status("wiring: aim at (or stand near) a node to open it")
		return
	bind_object(id)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

## THE SHARED BACKEND FN (one function behind BOTH the GUI right-click and the headless text verb).
## Ensures the object's arrangement file exists (seeding a starter graph if new) and mounts the GraphPanel
## overlay pointed at it. `force` mounts the real overlay headless (the #049 test hook). Returns the
## arrangement path bound (or "" on failure). This is the text-equivalence anchor: bind_object_text()
## and the right-click both funnel here, so GUI and text drive identical behaviour.
func bind_object(id: String, force := false) -> String:
	if not objects.has(id):
		return ""
	var path := WiringTool.ensure_arrangement(id)
	GraphPanelMount.open_panel(self, path, force)
	_set_status("node panel open: %s (ESC to close, edits are live)" % id)
	return path

## TEXT VERB (gate T — text-equivalence): open a node panel by object id with no GUI, driving the EXACT
## same backend (bind_object) and the same real overlay (force=true). A headless caller gets the same
## mounted GraphPanel + the same arrangement file the right-click would produce. Returns the bound path.
func bind_object_text(id: String) -> String:
	return bind_object(id, true)

## Close the node panel overlay (ESC). Recaptures the mouse so movement resumes, like _close_board.
func _close_wiring_panel() -> void:
	if GraphPanelMount.close_panel(self):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_set_status("closed node panel (edits saved + live)")


# == IN-SCENE FEEDBACK (F) - append to notes.jsonl keyed to scene id "aperture_3d" =================

func _open_note() -> void:
	if _headless or _note_panel == null:
		return
	_note_open = true
	_note_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_note_edit.text = ""
	_note_edit.grab_focus()


func _close_note(save: bool) -> void:
	_note_open = false
	if _note_panel != null:
		_note_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if not save:
		return
	var text := _note_edit.text.strip_edges() if _note_edit != null else ""
	if text == "":
		return
	_set_status("feedback saved -> notes.jsonl" if _write_note(text) else "NOTE FAILED")


## Append one note line keyed to SCENE_ID "aperture_3d" - the SAME notes substrate + schema as the
## card feedback and the sandbox note (a note here is indistinguishable from a card note by data).
func _write_note(text: String, pos_override = null) -> bool:
	var pos: Vector3 = pos_override if pos_override != null else _pos
	var entry := {
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"scene": SCENE_ID,
		"world": WORLD_NAME,
		"object_id": selected_id,
		"asset_id": String((objects[selected_id] as Dictionary).get("asset", "")) if objects.has(selected_id) else "",
		"position": [pos.x, pos.y, pos.z],
		"note": text,
	}
	var dir := NOTES_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f: FileAccess
	if FileAccess.file_exists(NOTES_PATH):
		f = FileAccess.open(NOTES_PATH, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(NOTES_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line(JSON.stringify(entry))
	f.close()
	return true


# == HUD ===========================================================================================

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_hud.add_child(_crosshair)
	var ch := Label.new()
	ch.text = "+"
	ch.add_theme_font_size_override("font_size", 22)
	ch.position = Vector2(-7, -16)
	_crosshair.add_child(ch)
	# Defect #1 (Liam 2026-07-05): NO controls-explanation overlay on the aperture room.
	# Defect #2 (Liam 2026-07-05): NO inventory / hotbar HUD on the aperture room. The pick-up / remove /
	# place mechanics stay fully wired (input + slot state untouched; _hotbar_ui stays null so
	# _rebuild_hotbar_ui no-ops) - item-4 layout editing still works; only the visible bar is gone.
	# Defect (Liam 2026-07-06, re-reported): NO top-left status text in the aperture room. The green
	# "2D aperture open / back in the room / holding: ..." Label used to sit at (12,12); Liam asked for
	# it gone. _status stays NULL so _set_status() still runs its logic + console print (non-visual),
	# but nothing is drawn top-left. The room's top-left is now clean (only the centered crosshair).
	_status = null
	_build_note_panel()


func _rebuild_hotbar_ui() -> void:
	if _hotbar_ui == null:
		return
	for c in _hotbar_ui.get_children():
		c.queue_free()
	for i in hotbar.size():
		var entry: Dictionary = palette[hotbar[i]]
		var b := Button.new()
		b.custom_minimum_size = Vector2(58, 40)
		b.clip_text = true
		b.text = "%d\n%s" % [i, String(entry.get("name", "-")).left(8)]
		b.add_theme_font_size_override("font_size", 10)
		var col_arr = entry.get("material", {}).get("albedo", [0.4, 0.4, 0.44])
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(col_arr[0], col_arr[1], col_arr[2]).darkened(0.25)
		sb.set_border_width_all(3)
		sb.border_color = Color(1, 1, 0.4) if i == active_slot else Color(0.15, 0.15, 0.18)
		for st in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(st, sb)
		var idx := i
		b.pressed.connect(func(): _select_slot(idx))
		_hotbar_ui.add_child(b)


func _build_note_panel() -> void:
	_note_panel = Panel.new()
	_note_panel.set_anchors_preset(Control.PRESET_CENTER)
	_note_panel.custom_minimum_size = Vector2(460, 120)
	_note_panel.size = Vector2(460, 120)
	_note_panel.position = Vector2(-230, -60)
	_note_panel.visible = false
	_hud.add_child(_note_panel)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 12; v.offset_top = 10; v.offset_right = -12; v.offset_bottom = -12
	_note_panel.add_child(v)
	var lbl := Label.new()
	lbl.text = "Feedback on the 3D aperture (Enter saves - ESC cancels)"
	lbl.add_theme_font_size_override("font_size", 13)
	v.add_child(lbl)
	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "Type a note / change for this scene..."
	v.add_child(_note_edit)
	_note_edit.text_submitted.connect(func(_t): _close_note(true))


func _set_status(msg: String) -> void:
	if _status != null:
		var held := "empty hand" if _is_empty_hand() else String(palette[hotbar[active_slot]].get("name", "?"))
		_status.text = "%s  -  holding: %s" % [msg, held]
	print("[aperture_3d] ", msg)


# == --shot proof ==================================================================================

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()


func _shot_board_requested() -> bool:
	return "--shot-board" in OS.get_cmdline_user_args() or "--shot-board" in OS.get_cmdline_args()


func _shot_home_door_requested() -> bool:
	return "--shot-home-door" in OS.get_cmdline_user_args() or "--shot-home-door" in OS.get_cmdline_args()


## Windowed proof that the NEW Home door is present in the current aperture room (Liam 2026-07-06 slice
## 1). Frames the +X wall where the Home door sits, so the screenshot shows the glowing door + its
## "Home" lintel sign inside the room, then quits. --shot-home-door needs a display.
func _take_home_door_shot() -> void:
	_did_shot = true
	if _headless:
		print("[aperture_3d] --shot-home-door needs a display. Exit 2.")
		get_tree().quit(2)
		return
	# Stand in the room facing the +X wall (where the Home door is at [11.4,0,0]); the door + sign fill frame.
	_pos = Vector3(4.0, 1.9, 0.0)
	_cam.position = _pos
	_yaw = deg_to_rad(-90.0)   # look toward +X
	_pitch = 0.05
	_apply_camera_rotation()
	await get_tree().create_timer(1.0).timeout
	for _i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out := "res://docs/aperture_home_door.png"
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(out)
	print("[aperture_3d] home-door proof written: %s" % out)
	get_tree().quit(0)


## Windowed proof that the 3D computer opens the 2D board as a SAME-WINDOW overlay (spec item 4).
## Programmatically mounts the board (the exact call the empty-hand right-click makes), captures it,
## then quits — the interaction the mouse-less --shot cannot exercise.
func _take_board_shot() -> void:
	_did_shot = true
	if _headless:
		print("[aperture_3d] --shot-board needs a display. Exit 2.")
		get_tree().quit(2)
		return
	_open_board()
	await get_tree().create_timer(2.0).timeout
	for _i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var out := "res://docs/aperture_3d_board_overlay.png"
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(out)
	print("[aperture_3d] board-overlay proof written: %s (board_is_open=%s)" %
		[out, str(ComputerTerminal.board_is_open(self))])
	get_tree().quit(0)


func _take_shot() -> void:
	_did_shot = true
	if _headless:
		print("[aperture_3d] --shot needs a display. Exit 2.")
		get_tree().quit(2)
		return
	# Seed a small demo layout so the proof shows the room's features.
	_place_block(palette[1], Vector3(-2.0, 0.5, 2.0))
	_place_block(palette[3], Vector3(1.5, 0.6, 1.0))
	_place_block(palette[4], Vector3(0.0, 0.5, -1.0))
	await get_tree().create_timer(1.5).timeout
	_pos = Vector3(4.0, 2.4, 7.0)
	_cam.position = _pos
	_yaw = deg_to_rad(-22.0)
	_pitch = -0.15
	_apply_camera_rotation()
	for _i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(SHOT_PATH)
	print("[aperture_3d] proof written: %s" % SHOT_PATH)
	get_tree().quit(0)
