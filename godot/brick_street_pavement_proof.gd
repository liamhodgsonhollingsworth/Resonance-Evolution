extends Node3D
## brick_street_pavement_proof -- the brick-street-realism-2026-07-16 lane's render driver (Liam
## verbatim, Discord #dev, 2026-07-16T02:11:38Z), EXTENDED by the brick-wall-generator-2026-07-16
## lane (DQ-e732faee) to also drive the facade generator. Replaces the prior street-surface
## placeholder (Kenney's modern asphalt City Kit Roads, `brick_street_real_kit_proof.gd`, PR #203)
## with REAL researched brick construction end to end: `StreetGridScaffold`'s lot/street layout
## (UNCHANGED, merged PR #202) feeds BOTH `BrickPavementGenerator` (street SURFACE, PR #206) and
## `BrickWallGenerator` (facade walls -- running/common/Flemish coursing, header courses, lintel/sill
## openings, corner toothing, DQ-e732faee, this lane) instead of `KitGridPlacer`'s road-tile fill and
## the plain placeholder box, respectively. `BrickWallGenerator`'s own docstring covers its full
## research/physical-seed design; this driver only wires it in.
##
## SEED GUI (Liam 2026-07-16: "use some menu or GUI to change the seed that the rest of the examples
## generate from" + "every parameter... exposed... for me to change them"): every free_param of
## `StreetGridScaffold`, `BrickPavementGenerator`, AND (as of this lane) `BrickWallGenerator` is a
## live `TunablePanel` slider/dropdown, wired over the SAME `param_channel`/`ws://` transport the
## underground scene already proved out (DQ-0343912a, Wavelet PR #910's protocol,
## `tools/param_channel_client.gd`) -- so the browser knob panel / cross-window tuning convention
## Just Works here too, zero new transport. Wall param keys are prefixed `wall_` to avoid colliding
## with the pavement generator's own same-named params (both nodes independently expose
## `seed_handle`/`seed`/`mortar_gap`).
##
## Launch modes (same shape as underground_wave6_proof.gd, this corpus's own established pattern):
##   <godot> --path godot res://brick_street_pavement_proof.tscn -- --shot
##     Fixed-camera smoke-test capture -> godot/live/brick_street_pavement_proof.png, quits.
##   <godot> --path godot res://brick_street_pavement_proof.tscn -- --milestone-shot
##     Closer/lower framing chosen to make the herringbone coursing + crown + curb/gutter legible
##     (not just a tiny texture from a high oblique) -> godot/live/brick_street_pavement_milestone.png.
##   <godot_console, WITHOUT --headless -- see tools/scene_smoketest.py docstring for why>
##       --path godot res://brick_street_pavement_proof.tscn -- --param-listen --channel-uri ws://127.0.0.1:8790/brick_street [--listen-seconds 20] [--min-updates 3]
##     DQ-0343912a-shaped: applies every received param to the SAME `_rebuild_geometry()` path a
##     local slider drag would use, writes `godot/live/brick_street_param_state.json` after every
##     applied change (state read-back verification, since headless texture readback is unreliable on
##     this engine build).
##   <godot> --path godot res://brick_street_pavement_proof.tscn
##     Interactive: TunablePanel visible top-left, drag any slider to regenerate live.

const SHOT_OUT := "res://live/brick_street_pavement_proof.png"
const MILESTONE_SHOT_OUT := "res://live/brick_street_pavement_milestone.png"
const PARAM_LISTEN_SHOT_OUT := "res://live/brick_street_param_wiring_proof.png"
const PARAM_STATE_OUT := "res://live/brick_street_param_state.json"

const HERRINGBONE_SEED := "res://assets/paver_exemplars/herringbone_2brick.json"
const RUNNING_BOND_SEED := "res://assets/paver_exemplars/running_bond_1brick.json"

const WALL_RUNNING_SEED := "res://assets/wall_exemplars/running_bond_wall.json"
const WALL_COMMON_SEED := "res://assets/wall_exemplars/common_bond_wall.json"
const WALL_FLEMISH_SEED := "res://assets/wall_exemplars/flemish_bond_wall.json"
const WALL_STACK_TSCN_SEED := "res://assets/wall_exemplars/stack_bond_wall_exemplar.tscn"

const WORLD_SEED := 2026
const CHUNK_COORD := Vector2i(0, 0)

var _geometry_root: Node3D
var _tunable_panel: TunablePanel
var _main_camera: Camera3D
var _shot_frames := 0
var _param_channel: ParamChannelClient = null
var _param_listen_mode := false
var _param_listen_elapsed_ms := 0
var _param_listen_deadline_ms := 20000
var _param_listen_min_updates := 0
var _current_tunables: Dictionary = {}
var _rebuild_count := 0
var _applying_external_param := false
var _shot_mode := false
var _milestone_shot_mode := false
var _capture_out := SHOT_OUT


func _ready() -> void:
	var user_args := OS.get_cmdline_user_args()
	var raw_args := OS.get_cmdline_args()
	_milestone_shot_mode = "--milestone-shot" in user_args or "--milestone-shot" in raw_args
	_shot_mode = _milestone_shot_mode or "--shot" in user_args or "--shot" in raw_args
	if _milestone_shot_mode:
		_capture_out = MILESTONE_SHOT_OUT
	_param_listen_mode = _cmdline_flag("--param-listen")
	var channel_uri := _cmdline_value("--channel-uri", "")
	_param_listen_deadline_ms = int(_cmdline_value("--listen-seconds", "20")) * 1000
	_param_listen_min_updates = int(_cmdline_value("--min-updates", "0"))

	_geometry_root = Node3D.new()
	add_child(_geometry_root)

	_build_env()
	_build_camera()

	if channel_uri != "":
		_param_channel = ParamChannelClient.new(channel_uri)

	if not _shot_mode and not _param_listen_mode:
		_tunable_panel = TunablePanel.new()
		var layer := CanvasLayer.new()
		layer.layer = 40
		add_child(layer)
		_tunable_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_tunable_panel.position = Vector2(12, 12)
		layer.add_child(_tunable_panel)
		_tunable_panel.configure(_param_specs(), _on_tunable_changed)

	_current_tunables = _default_tunables()
	_rebuild_geometry(_current_tunables)

	if _shot_mode or _param_channel != null:
		set_process(true)


func _default_tunables() -> Dictionary:
	var out := {}
	for spec in _param_specs():
		out[spec["key"]] = spec["default"]
	return out


func _cmdline_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args() or flag in OS.get_cmdline_args()


func _cmdline_value(flag: String, default_v: String) -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == flag and i + 1 < args.size():
			return args[i + 1]
	return default_v


## Every free_param of BOTH StreetGridScaffold (scaffolding) and BrickPavementGenerator (the
## construction/assembly realism this lane adds) is a live knob -- "every parameter... exposed... for
## me to change them" (Liam, matching the underground scene's own precedent, DQ-0343912a).
func _param_specs() -> Array:
	return [
		# ── StreetGridScaffold (scaffolding tier, unchanged upstream) ──────────────────────────────
		{"key": "chunk_size", "label": "chunk_size", "type": "float", "min": 8.0, "max": 48.0, "step": 1.0, "default": 20.0},
		{"key": "lot_size_min", "label": "lot_size_min", "type": "float", "min": 2.0, "max": 20.0, "step": 0.5, "default": 4.0},
		{"key": "lot_size_max", "label": "lot_size_max", "type": "float", "min": 3.0, "max": 30.0, "step": 0.5, "default": 7.0},
		{"key": "street_width", "label": "street_width", "type": "float", "min": 1.5, "max": 8.0, "step": 0.1, "default": 3.0},
		{"key": "packing_seed", "label": "packing_seed (layout)", "type": "int", "min": 0, "max": 9999, "step": 1, "default": 7},
		# ── BrickPavementGenerator: physical seed / pattern ────────────────────────────────────────
		{"key": "seed_handle", "label": "paving pattern (physical seed)", "type": "enum",
			"options": [HERRINGBONE_SEED, RUNNING_BOND_SEED], "default": HERRINGBONE_SEED},
		{"key": "seed", "label": "brick seed (weathering jitter)", "type": "int", "min": 0, "max": 9999, "step": 1, "default": 1},
		# ── BrickPavementGenerator: real construction layers ───────────────────────────────────────
		{"key": "mortar_gap", "label": "joint width (m)", "type": "float", "min": 0.0, "max": 0.02, "step": 0.001, "default": 0.005},
		{"key": "joint_mode", "label": "joint mode", "type": "enum", "options": ["sand_set", "mortar_set"], "default": "sand_set"},
		{"key": "crown_height", "label": "crown height (m)", "type": "float", "min": 0.0, "max": 0.15, "step": 0.005, "default": 0.03},
		{"key": "curb_reveal_height", "label": "curb reveal height (m)", "type": "float", "min": 0.0, "max": 0.3, "step": 0.01, "default": 0.12},
		{"key": "curb_width", "label": "curb width (m)", "type": "float", "min": 0.05, "max": 0.5, "step": 0.01, "default": 0.15},
		{"key": "gutter_width", "label": "gutter width (m)", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.3},
		{"key": "aggregate_base_thickness", "label": "aggregate base thickness (m)", "type": "float", "min": 0.05, "max": 0.3, "step": 0.01, "default": 0.15},
		{"key": "binder_thickness", "label": "binder layer thickness (m)", "type": "float", "min": 0.0, "max": 0.08, "step": 0.005, "default": 0.03},
		{"key": "bedding_thickness", "label": "bedding sand thickness (m)", "type": "float", "min": 0.005, "max": 0.06, "step": 0.005, "default": 0.025},
		{"key": "brick_thickness", "label": "brick thickness (m)", "type": "float", "min": 0.02, "max": 0.08, "step": 0.005, "default": 0.05},
		# ── BrickWallGenerator: facade physical seed / bond (DQ-e732faee) ──────────────────────────
		{"key": "wall_seed_handle", "label": "wall bond (physical seed)", "type": "enum",
			"options": [WALL_RUNNING_SEED, WALL_COMMON_SEED, WALL_FLEMISH_SEED, WALL_STACK_TSCN_SEED], "default": WALL_RUNNING_SEED},
		{"key": "wall_seed", "label": "wall brick seed (weathering jitter)", "type": "int", "min": 0, "max": 9999, "step": 1, "default": 1},
		{"key": "wall_mortar_gap", "label": "wall joint width (m)", "type": "float", "min": 0.0, "max": 0.02, "step": 0.0005, "default": 0.0095},
		# ── BrickWallGenerator: facade geometry ─────────────────────────────────────────────────────
		{"key": "wall_height", "label": "wall height (m)", "type": "float", "min": 1.5, "max": 12.0, "step": 0.1, "default": 3.3},
		{"key": "wall_row_count", "label": "window rows (floors)", "type": "int", "min": 1, "max": 6, "step": 1, "default": 3},
		{"key": "wall_window_width", "label": "window width (m)", "type": "float", "min": 0.5, "max": 2.5, "step": 0.05, "default": 1.1},
		{"key": "wall_window_height", "label": "window height (m)", "type": "float", "min": 0.6, "max": 2.8, "step": 0.05, "default": 1.6},
		{"key": "wall_window_spacing", "label": "window spacing (m)", "type": "float", "min": 0.3, "max": 4.0, "step": 0.05, "default": 1.5},
		{"key": "wall_sill_height_above_floor", "label": "sill height above floor (m)", "type": "float", "min": 0.3, "max": 1.5, "step": 0.05, "default": 0.9},
		{"key": "wall_ground_floor_door", "label": "ground-floor door", "type": "bool", "default": true},
		{"key": "wall_door_width", "label": "door width (m)", "type": "float", "min": 0.7, "max": 1.8, "step": 0.05, "default": 1.0},
		{"key": "wall_door_height", "label": "door height (m)", "type": "float", "min": 1.8, "max": 2.6, "step": 0.05, "default": 2.1},
		{"key": "wall_lintel_overhang", "label": "lintel overhang (m)", "type": "float", "min": 0.0, "max": 0.3, "step": 0.01, "default": 0.1},
		{"key": "wall_sill_projection", "label": "sill projection (m)", "type": "float", "min": 0.0, "max": 0.1, "step": 0.005, "default": 0.02},
	]


func _on_tunable_changed(key: String, value: Variant) -> void:
	if _applying_external_param:
		return
	_current_tunables[key] = value
	if _param_channel != null:
		_param_channel.publish(key, value)
	_rebuild_geometry(_current_tunables)
	_rebuild_count += 1
	if _param_channel != null:
		_write_state_json()


func _apply_external_param(key: String, value: Variant) -> void:
	_applying_external_param = true
	_current_tunables[key] = value
	if _tunable_panel != null:
		_tunable_panel.set_value(key, value)
	_rebuild_geometry(_current_tunables)
	_rebuild_count += 1
	_write_state_json()
	_applying_external_param = false


func _write_state_json() -> void:
	var out := {
		"schema_version": 1,
		"updated_at_unix": Time.get_unix_time_from_system(),
		"rebuild_count": _rebuild_count,
		"tunables": _current_tunables,
	}
	DirAccess.make_dir_recursive_absolute("res://live")
	var f := FileAccess.open(PARAM_STATE_OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()


func _build_env() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(10.0, 6.0, 10.0)
	fill.light_energy = 2.0
	fill.omni_range = 40.0
	add_child(fill)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.72, 0.82)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.9
	env_node.environment = env
	add_child(env_node)


func _build_camera() -> void:
	var cam := Camera3D.new()
	if _milestone_shot_mode:
		# Closer/lower, angled along the street's length so the herringbone coursing, the crown's
		# subtle center-rise, and both curb+gutter lines are all legible in one frame -- not just a
		# high oblique that reduces the paving to a texture smudge.
		var target := Vector3(8.944, 1.5, 9.156)
		var cpos := target + Vector3(2.2, 0.1, 2.2)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 45.0
	else:
		var target2 := Vector3(10.0, 0.0, 10.0)
		var cpos2 := target2 + Vector3(11.0, 17.0, 11.0)
		cam.transform = Transform3D(Basis.looking_at(target2 - cpos2, Vector3.UP), cpos2)
		cam.fov = 50.0
	cam.current = true
	add_child(cam)
	_main_camera = cam


func _rebuild_geometry(t: Dictionary) -> void:
	for c in _geometry_root.get_children():
		c.queue_free()

	var chunk_size: float = float(t.get("chunk_size", 20.0))
	var lot_size_min: float = float(t.get("lot_size_min", 4.0))
	var lot_size_max: float = float(t.get("lot_size_max", 7.0))
	var street_width: float = float(t.get("street_width", 3.0))
	var packing_seed: int = int(t.get("packing_seed", 7))

	var scaffold := StreetGridScaffold.build(WORLD_SEED, CHUNK_COORD, chunk_size,
		lot_size_min, lot_size_max, street_width, packing_seed)
	var building_footprints: Array = scaffold["building_footprints"]
	var street_polygon: Array = scaffold["street_polygon"]

	# ground verge under the whole chunk (grass either side of the lots, matches the prior proof's
	# framing so this stays a real "sits on a surface" composition, not floating geometry)
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(chunk_size, 0.1, chunk_size)
	ground.mesh = ground_mesh
	ground.position = Vector3(chunk_size * 0.5, -0.05, chunk_size * 0.5)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.36, 0.42, 0.3)
	ground.material_override = ground_mat
	_geometry_root.add_child(ground)

	# ── lots: REAL coursed brick walls (DQ-e732faee, this lane) -- replaces the prior placeholder
	# box (StreetGridScaffold.lot_box_mesh) with BrickWallGenerator's researched facade coursing.
	var wall_height: float = float(t.get("wall_height", 3.3))
	var wall_params := {
		"seed_handle": String(t.get("wall_seed_handle", WALL_RUNNING_SEED)),
		"seed": int(t.get("wall_seed", 1)),
		"mortar_gap": float(t.get("wall_mortar_gap", 0.0095)),
		"row_count": int(t.get("wall_row_count", 3)),
		"window_width": float(t.get("wall_window_width", 1.1)),
		"window_height": float(t.get("wall_window_height", 1.6)),
		"window_spacing": float(t.get("wall_window_spacing", 1.5)),
		"sill_height_above_floor": float(t.get("wall_sill_height_above_floor", 0.9)),
		"ground_floor_door": bool(t.get("wall_ground_floor_door", true)),
		"door_width": float(t.get("wall_door_width", 1.0)),
		"door_height": float(t.get("wall_door_height", 2.1)),
		"lintel_overhang": float(t.get("wall_lintel_overhang", 0.1)),
		"sill_projection": float(t.get("wall_sill_projection", 0.02)),
	}
	var total_wall_bricks := 0
	for f in building_footprints:
		var rect: Rect2 = f["rect"]
		var wresult := BrickWallGenerator.build(rect, wall_height, wall_params, 0.0)
		for mmi in BrickWallGenerator.wall_multimeshes(wresult):
			_geometry_root.add_child(mmi)
		for g in (wresult["brick_groups"] as Array):
			total_wall_bricks += (g["transforms"] as Array).size()
		# a thin roof cap so each building reads as an enclosed volume from above/oblique angles,
		# not an open shell -- simple flat placeholder, not this lane's research scope.
		var roof := MeshInstance3D.new()
		var roof_mesh := BoxMesh.new()
		roof_mesh.size = Vector3(maxf(0.01, rect.size.x), 0.15, maxf(0.01, rect.size.y))
		roof.mesh = roof_mesh
		var roof_mat := StandardMaterial3D.new()
		roof_mat.albedo_color = Color(0.32, 0.28, 0.26)
		roof.material_override = roof_mat
		roof.position = Vector3(rect.get_center().x, wall_height + 0.075, rect.get_center().y)
		_geometry_root.add_child(roof)

	# ── the real deliverable: every street strip gets a full researched construction stack ─────────
	var pave_params := {
		"seed_handle": String(t.get("seed_handle", HERRINGBONE_SEED)),
		"seed": int(t.get("seed", 1)),
		"mortar_gap": float(t.get("mortar_gap", 0.005)),
		"joint_mode": String(t.get("joint_mode", "sand_set")),
		"crown_height": float(t.get("crown_height", 0.03)),
		"curb_reveal_height": float(t.get("curb_reveal_height", 0.12)),
		"curb_width": float(t.get("curb_width", 0.15)),
		"gutter_width": float(t.get("gutter_width", 0.3)),
		"aggregate_base_thickness": float(t.get("aggregate_base_thickness", 0.15)),
		"binder_thickness": float(t.get("binder_thickness", 0.03)),
		"bedding_thickness": float(t.get("bedding_thickness", 0.025)),
		"brick_thickness": float(t.get("brick_thickness", 0.05)),
	}

	var total_pavers := 0
	for strip in street_polygon:
		var rect: Rect2 = strip
		var result := BrickPavementGenerator.build(rect, pave_params, 0.0)
		for layer in (result["layers"] as Array):
			var lmi := MeshInstance3D.new()
			lmi.mesh = layer["mesh"]
			lmi.position = layer["position"]
			var lmat := StandardMaterial3D.new()
			lmat.albedo_color = layer["color"]
			lmat.roughness = 0.95
			lmi.material_override = lmat
			_geometry_root.add_child(lmi)
		for curb in (result["curbs"] as Array):
			var cmi := MeshInstance3D.new()
			cmi.mesh = curb["mesh"]
			cmi.position = curb["position"]
			var cmat := StandardMaterial3D.new()
			cmat.albedo_color = curb["color"]
			cmat.roughness = 0.7
			cmi.material_override = cmat
			_geometry_root.add_child(cmi)
		var mmi := BrickPavementGenerator.paver_multimesh(result)
		_geometry_root.add_child(mmi)
		total_pavers += (result["paver_transforms"] as Array).size()

	print("[brick_street_pavement_proof] rebuilt: %d lots (%d facade bricks, wall bond=%s), %d street strips, %d real brick pavers placed (paving pattern=%s)" %
		[building_footprints.size(), total_wall_bricks, wall_params["seed_handle"], street_polygon.size(), total_pavers, pave_params["seed_handle"]])


func _process(delta: float) -> void:
	if _param_channel != null:
		_param_channel.poll()
		var incoming := _param_channel.drain_latest()
		for key in incoming.keys():
			_apply_external_param(key, incoming[key])

	if _param_listen_mode:
		var prev_elapsed_ms := _param_listen_elapsed_ms
		_param_listen_elapsed_ms += int(delta * 1000.0)
		if _param_channel != null and _param_listen_elapsed_ms / 5000 != prev_elapsed_ms / 5000:
			print("[brick_street_pavement_proof] param-listen t=%ds channel=%s rebuild_count=%d" %
				[_param_listen_elapsed_ms / 1000, _param_channel.state_string(), _rebuild_count])
		var deadline_hit := _param_listen_elapsed_ms >= _param_listen_deadline_ms
		var min_updates_hit := _param_listen_min_updates > 0 and _rebuild_count >= _param_listen_min_updates
		if deadline_hit or min_updates_hit:
			set_process(false)
			await _capture(PARAM_LISTEN_SHOT_OUT)
			_write_state_json()
			print("[brick_street_pavement_proof] param-listen captured -> ", PARAM_LISTEN_SHOT_OUT, "  (rebuild_count=", _rebuild_count, ")")
			get_tree().quit(0)
		return

	if not _shot_mode:
		return
	_shot_frames += 1
	if _shot_frames == 20:
		await _capture(_capture_out)
		print("[brick_street_pavement_proof] captured -> ", _capture_out)
		get_tree().quit(0)


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
