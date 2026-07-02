extends Node3D
## OPENABLE PROJECTION-MAPPING SIMULATION DEMO — a simulated projector above an ANGLED PLANE
## projecting a calibration grid, self-calibrating live via the camera-feedback loop
## (ProjectionObserve -> ProjectionCalibration -> ProjectionMap), everything an arrangement of
## registered primitives wired as DATA (examples/projection_sim.json).
##
## What you see: the angled screen, the projector beam (a SpotLight3D whose light_projector
## cookie IS the warped calibration pattern), green pins where the dots SHOULD land, and a HUD
## with the mean alignment error falling each correction step until convergence (< 1 px).
## The calibration math is the CPU seam (ProjectionMath) — the SAME numbers the headless test
## asserts; the spotlight is its live visualization.
##
## ── HOW TO OPEN + ITERATE ────────────────────────────────────────────────────────────────────
##   Live (stays open, steps the loop every ~1.2 s, HOT-RELOADS the arrangement):
##     <Godot> --path godot res://examples/projection_sim_demo.tscn
##   Proof shot (steps to convergence, saves docs/projection_sim_demo.png, quits):
##     <Godot> --path godot res://examples/projection_sim_demo.tscn -- --shot
##   (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe.)
##
##   THE ONE FILE TO EDIT:  godot/examples/projection_sim.json — move the projector, tilt the
##   screen, change the grid, retune gain/threshold; SAVE and the demo reloads + recalibrates.
##   Swap the surface node's params to the cylinder kind and the same loop calibrates a curved
##   screen to its best-fit floor.

const ARRANGEMENT := "res://examples/projection_sim.json"
const SHOT_PATH := "res://docs/projection_sim_demo.png"
const STEP_SECONDS := 1.2

var runtime: GraphRuntime
var arr: Dictionary = {}
var _light: SpotLight3D
var _hud: Label
var _pins: Node3D
var _screen: Node3D
var _step_timer := 0.0
var _iteration := 0
var _converged := false
var _mtime := -1
var _shot := false

func _ready() -> void:
	_shot = "--shot" in OS.get_cmdline_user_args()
	runtime = GraphRuntime.new()
	add_child(runtime)
	_build_static()
	_reload()
	if _shot:
		_run_shot()

func _process(delta: float) -> void:
	if _shot:
		return
	# Hotload: the arrangement file is the live control surface.
	var mt := FileAccess.get_modified_time(ProjectSettings.globalize_path(ARRANGEMENT))
	if _mtime >= 0 and mt != _mtime:
		_reload()
		return
	if _converged:
		return
	_step_timer += delta
	if _step_timer >= STEP_SECONDS:
		_step_timer = 0.0
		_step()

## One correction step: evaluate the graph, show the state, commit calib.warp into the map
## node's DATA (the same data-driven feedback edge the headless test drives).
func _step() -> void:
	var out := runtime.evaluate()
	var err := float(out["calib"]["error"])
	_apply_visuals(out)
	if _iteration == 0:
		_hud.text = "projection sim — iteration 0 (uncalibrated)\nmean error: %.2f px" % err
	else:
		_hud.text = "projection sim — iteration %d\nmean error: %.2f px" % [_iteration, err]
	if bool(out["calib"]["converged"]):
		_converged = true
		_hud.text += "\nCONVERGED (< %.1f px) — edit projection_sim.json to perturb" % \
			float(_node_params("calib").get("threshold", 1.0))
		return
	_node_params("map")["matrix"] = out["calib"]["warp"]
	runtime.load_arrangement(arr)
	_iteration += 1

func _reload() -> void:
	var data = JSON.parse_string(FileAccess.get_file_as_string(ARRANGEMENT))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("projection demo: bad arrangement JSON")
		return
	arr = data
	_mtime = FileAccess.get_modified_time(ProjectSettings.globalize_path(ARRANGEMENT))
	_iteration = 0
	_converged = false
	_step_timer = 0.0
	runtime.load_arrangement(arr)
	var out := runtime.evaluate()
	_rebuild_scene(out)
	_apply_visuals(out)
	_hud.text = "projection sim — iteration 0 (uncalibrated)\nmean error: %.2f px" % float(out["calib"]["error"])

# ── scene assembly (all FROM the evaluated arrangement data) ─────────────────────────────────

func _build_static() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.03, 0.03, 0.05)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.6)
	e.ambient_light_energy = 0.25  # dim room, so the beam reads
	env.environment = e
	add_child(env)
	var cam := Camera3D.new()
	cam.name = "WitnessCamera"
	add_child(cam)
	var hud_layer := CanvasLayer.new()
	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 22)
	_hud.add_theme_color_override("font_color", Color(0.9, 1.0, 0.9))
	hud_layer.add_child(_hud)
	add_child(hud_layer)

func _rebuild_scene(out: Dictionary) -> void:
	# The screen: the surface node's own scene_node twin (same pose/extent as the math).
	if _screen != null:
		_screen.queue_free()
	_screen = Node3D.new()
	add_child(_screen)
	GodotSceneRenderer.build_static_tree([out["surface"]["node"]], _screen)
	# Target pins: green markers at each intended landing point on the surface.
	if _pins != null:
		_pins.queue_free()
	_pins = Node3D.new()
	add_child(_pins)
	var surface: Dictionary = out["surface"]["surface"]
	var rect = _node_params("observe").get("target_rect", [0.3, 0.3, 0.7, 0.7])
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 1.0, 0.35)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.8, 0.25)
	for pt in out["pattern"]["pattern"]["points"]:
		var su := float(rect[0]) + float(pt["u"]) * (float(rect[2]) - float(rect[0]))
		var sv := float(rect[3]) - float(pt["v"]) * (float(rect[3]) - float(rect[1]))
		var sp := ProjectionMath.surface_point(surface, Vector2(su, sv))
		var pin := MeshInstance3D.new()
		var m := SphereMesh.new()
		m.radius = 0.012
		m.height = 0.024
		pin.mesh = m
		pin.material_override = mat
		pin.position = (sp["point"] as Vector3) + (sp["normal"] as Vector3) * 0.005
		_pins.add_child(pin)
	# The projector body: a small box at the projector pose (so the rig is visible).
	var old := get_node_or_null("ProjectorBody")
	if old != null:
		old.queue_free()
	var projector: Dictionary = out["projector"]["projector"]
	var body := MeshInstance3D.new()
	body.name = "ProjectorBody"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.22, 0.09, 0.16)
	body.mesh = bm
	body.transform = PrimProjectionObserve.projector_pose(projector)
	add_child(body)

## Per-step visuals: re-rasterize the (warped) pattern into the spotlight cookie and re-seat
## the witness camera from the View descriptor.
func _apply_visuals(out: Dictionary) -> void:
	var projector: Dictionary = out["projector"]["projector"]
	var input_img := ProjectionRealizer.rasterize_input(
		projector["pattern"], projector["map"], projector["resolution"])
	if _light == null or not is_instance_valid(_light):
		_light = ProjectionRealizer.make_spotlight(projector, input_img)
		add_child(_light)
	else:
		ProjectionRealizer.drive_spotlight(_light, projector, input_img)
	var cam := get_node("WitnessCamera") as Camera3D
	GodotSceneRenderer.drive_camera(cam, out["view"]["view"], [])
	cam.current = true

# ── proof-shot mode ──────────────────────────────────────────────────────────────────────────

func _run_shot() -> void:
	_reload()
	await _settle()
	var before: Image = get_viewport().get_texture().get_image()
	for i in 12:
		_step()
		if _converged:
			break
	await _settle()
	var after: Image = get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	ProjectionRealizer.side_by_side(before, after).save_png(SHOT_PATH)
	print("projection demo shot -> ", SHOT_PATH)
	get_tree().quit(0)

func _settle() -> void:
	for i in 8:
		await get_tree().process_frame

func _node_params(id: String) -> Dictionary:
	for n in arr.get("nodes", []):
		if String(n.get("id")) == id:
			if typeof(n.get("params")) != TYPE_DICTIONARY:
				n["params"] = {}
			return n["params"]
	return {}
