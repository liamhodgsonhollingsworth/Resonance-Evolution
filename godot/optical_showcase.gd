extends Node3D
## OPTICAL SHOWCASE (Convergence cycle #1) — an ENCLOSED FOREST that produces visible SUNBEAMS.
##
## Liam's felt-experience #1: stand inside an enclosed scene (a forest canopy) where a low sun rakes
## through the trunks and gaps, and SEE god-rays + lens-flare + bloom — then confirm the SAME effect-
## stack DATA paints the SAME look in a different renderer (the three.js web delegate). This scene is
## the Godot half of that proof: it
##   (1) assembles an enclosed ring of CC0 forest GLBs (pines + twisted trees) around a clearing, on a
##       floor, with a bright sky + a sun disc visible through a deliberate canopy GAP — the bright
##       pixels of that gap ARE the ray-emitting source (no depth buffer needed; the typed-I/O contract);
##   (2) renders it to a viewport color frame through GodotSceneRenderer (the only Godot-coupled delegate)
##       over the SAME renderer-neutral arrangement seam walkabout/gallery use;
##   (3) projects the sun's world direction to a SCREEN position (light_screen, [u,v] 0..1) — the one
##       piece of renderer-specific DATA the optical layers consume;
##   (4) applies the effect-stack DATA [god_rays, lens_flare, bloom] via EffectStackCpu.apply_io (the
##       headless-safe CPU reference oracle — headless Godot has no GPU, so the CPU applier IS the
##       ground truth a GPU/shader/three.js delegate must match);
##   (5) writes, for the run: a PAINTED still, a _raw baseline, and the EXACT effect-stack DATA as JSON
##       (so the web delegate consumes byte-identical DATA, proving renderer-independence).
##
## NO engine/foundation edit: a forest is just a different arrangement of Model -> Transform DATA + a
## sun + a sky, exactly like walkabout/gallery; the optical look is the effect_stack descriptor, applied
## at capture by the existing CPU applier. This is a registered scene, not a new primitive.
##
## Launch / capture (matches the convergence command pattern):
##   <godot> --path godot --resolution 960x540 res://optical_showcase.tscn -- --shot --out=<dir>
## Headless smoke (no GPU capture; proves assemble->render->project->apply path runs + writes DATA):
##   <godot> --headless --path godot res://optical_showcase.tscn

const PINE_DIR := "res://assets/vendor/quaternius_nature/"
const SHOT_FRAMES_BEFORE_CAPTURE := 20  # let TAA/light settle before grabbing the frame

# Geometry convention: the scene "opens" toward -Z (Godot's camera default look direction). The SUN
# sits low and far down -Z, slightly above the horizon, so the camera (in the clearing, looking -Z)
# frames it through a deliberate canopy gap. SUN_DIR is the direction the LIGHT TRAVELS (sun -> scene):
# from the far -Z sun toward the camera, i.e. mostly +Z and slightly down. The sun DISC is placed at
# -SUN_DIR * distance (far down -Z, raised) so the camera literally sees a bright sun ahead.
const SUN_DIR := Vector3(0.06, -0.16, 0.985)   # travels +Z (toward camera) + a touch down
const SUN_COLOR := Color(1.0, 0.92, 0.70)
# Where the bright sun disc sits in the world (far ahead down -Z, low on the horizon).
const SUN_WORLD := Vector3(-3.0, 7.0, -70.0)
# The camera stands IN THE CLEARING (near the centre, inside the innermost ring), low, looking down -Z
# through the canopy gap toward the sun. NOTE: z must stay small (< the inner ring radius of 5) or the
# camera ends up buried in the BACK wall of trunks (z=+12 sat between the r=11.5 and r=15 back rings →
# extreme trunk close-up). z≈3.5 keeps it in the open clearing with the enclosure ringing the periphery.
const CAM_POS := Vector3(0.0, 1.6, 3.5)
const CAM_LOOK := Vector3(-1.5, 5.5, -40.0)

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _cam: Camera3D
var _sun: DirectionalLight3D
var _sun_disc: MeshInstance3D
var _shot_frames := 0
var _out_dir := ""

func _ready() -> void:
	_out_dir = _parse_out_dir()
	_build_environment()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	var arrangement := assemble_arrangement()
	runtime.load_arrangement(arrangement)
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	print("[optical_showcase] ready; %d runtime node(s); %d rendered object(s); out=%s" % [
		runtime.nodes.size(), renderer.get_child_count(), _out_dir if _out_dir != "" else "(default)"])
	# Always write the effect-stack DATA + a manifest stub so the web delegate has its input even in a
	# headless run that can't capture a GPU frame.
	_write_effect_data()
	if not _shot_requested():
		if DisplayServer.get_name() == "headless":
			# Headless smoke: the path ran + DATA is written; quit so the test terminates
			# deterministically.
			get_tree().quit(0)
		# Windowed without --shot: STAY OPEN — this is the live viewable scene the Aperture demo
		# card opens (the sunbeam forest). Quitting here made the card's window close instantly.

func _process(_delta: float) -> void:
	if not _shot_requested():
		return
	_shot_frames += 1
	if _shot_frames == SHOT_FRAMES_BEFORE_CAPTURE:
		await _capture()
		get_tree().quit(0)

# --- the enclosed forest (floor + sky + sun disc + a ring of trees around a clearing) ---------------

func _build_environment() -> void:
	# Sky: a bright sun-lit gradient so there IS a luminous background for the canopy gap to frame. The
	# bright sky pixels through the gap are what the god-rays scatter (the typed-I/O bright-mask source).
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.35, 0.55, 0.85)
	sky_mat.sky_horizon_color = Color(0.92, 0.86, 0.70)
	sky_mat.ground_bottom_color = Color(0.10, 0.10, 0.12)
	sky_mat.ground_horizon_color = Color(0.55, 0.52, 0.45)
	sky_mat.sun_angle_max = 12.0
	sky_mat.energy_multiplier = 1.3
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	# A little built-in glow so even the GPU/windowed path reads bloomy (the CPU applier reproduces it as
	# DATA; this just makes the windowed view match what the painted still shows).
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.2
	env_node.environment = env
	add_child(env_node)

	# The sun: a low directional light raking through the trunks, plus a bright emissive sun DISC placed
	# along -SUN_DIR so the camera sees an actual bright sun (the ray source) through the canopy gap.
	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.light_color = SUN_COLOR
	_sun.light_energy = 1.6
	_sun.transform = Transform3D(Basis.looking_at(SUN_DIR, Vector3.UP), Vector3.ZERO)
	add_child(_sun)

	_sun_disc = MeshInstance3D.new()
	_sun_disc.name = "SunDisc"
	var disc := SphereMesh.new()
	disc.radius = 4.5
	disc.height = 9.0
	_sun_disc.mesh = disc
	var disc_mat := StandardMaterial3D.new()
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mat.albedo_color = Color(1.0, 0.98, 0.90)
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(1.0, 0.96, 0.82)
	disc_mat.emission_energy_multiplier = 8.0
	_sun_disc.mesh.surface_set_material(0, disc_mat)
	# The visible "sun in the sky": a bright unshaded disc far ahead (down -Z), the ray-emitting source.
	_sun_disc.position = SUN_WORLD
	add_child(_sun_disc)

	# A ground plane (forest floor) so the trees stand on something and the lower frame isn't pure sky.
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	floor_mi.mesh = plane
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.18, 0.20, 0.13)
	floor_mi.mesh.surface_set_material(0, floor_mat)
	floor_mi.position = Vector3(0, -0.02, 0)
	add_child(floor_mi)

	# The camera stands in the clearing, low, looking down -Z toward the sun through the canopy gap so
	# the beams rake across the field of view between the trunks.
	_cam = Camera3D.new()
	_cam.name = "Camera3D"
	_cam.transform = Transform3D(Basis.looking_at(CAM_LOOK - CAM_POS, Vector3.UP), CAM_POS)
	_cam.fov = 64.0
	_cam.current = true
	add_child(_cam)

# --- the arrangement: an ENCLOSED ring of forest GLBs around the clearing (Model -> Transform DATA) --

## Discover the CC0 forest GLBs (pines + twisted trees) vendored in-repo. Pure data read; no engine.
func _forest_glbs() -> Array:
	var out := []
	var d := DirAccess.open(PINE_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".glb") and (f.contains("pine") or f.contains("twisted_tree")):
			out.append(PINE_DIR + f)
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out

## Build a dense, ENCLOSING forest: several concentric rings of trees around the clearing, leaving a
## deliberate GAP toward the sun so beams stream through. Each tree is a Model -> Transform pair — the
## SAME renderer-neutral DATA walkabout/gallery emit; only the layout (an enclosure) differs. Public so
## the headless test can assemble + evaluate it directly without a window.
func assemble_arrangement() -> Dictionary:
	var nodes := []
	var wires := []
	var glbs := _forest_glbs()
	if glbs.is_empty():
		# Fallback: a single built-in box so the scene is never empty even with no assets ingested.
		nodes.append({ "id": "fallback", "type": "Model", "params": {} })
		return { "format": "resonance.arrangement/v1", "name": "optical_showcase", "nodes": nodes, "wires": wires }
	var idx := 0
	# Several concentric rings of increasing radius → a thick wall of trunks (the enclosure) around the
	# clearing the camera stands in. Trees per ring scale with radius so spacing stays roughly even. The
	# sun-facing arc (toward -Z, where the sun + camera-look point) is THINNED to leave a gap the beams
	# stream through. Position angle: x = r*sin(theta), z = -r*cos(theta) → theta=0 is straight ahead
	# (-Z, toward the sun); we skip a wedge around theta=0 so the canopy opens there.
	var rings := [
		{ "radius": 5.0, "count": 12 },
		{ "radius": 8.0, "count": 18 },
		{ "radius": 11.5, "count": 24 },
		{ "radius": 15.0, "count": 30 },
	]
	for ring in rings:
		var radius: float = ring["radius"]
		var count: int = ring["count"]
		for i in count:
			var theta := TAU * float(i) / float(count)
			# Leave a GAP toward the sun (theta ~ 0, i.e. straight ahead down -Z). Half-width ~22 degrees.
			# The two innermost rings keep a wider gap so the sun + beams are clearly framed; outer rings
			# close in more (a deeper canopy behind the gap).
			var gap_half := deg_to_rad(28.0) if radius < 9.0 else deg_to_rad(18.0)
			if absf(_angle_diff(theta, 0.0)) < gap_half:
				continue
			var x := radius * sin(theta)
			var z := -radius * cos(theta)  # theta=0 -> z=-radius (straight ahead, toward the sun)
			var glb: String = glbs[idx % glbs.size()]
			idx += 1
			# Vary scale + yaw deterministically (golden-ratio jitter) so the wall isn't a clone grid.
			var s := 1.1 + 0.7 * fposmod(float(idx) * 0.6180339887, 1.0)
			var yaw := 360.0 * fposmod(float(idx) * 0.3819660112, 1.0)
			var mid := "m_%d" % idx
			var tid := "t_%d" % idx
			nodes.append({ "id": mid, "type": "Model", "params": { "path": glb } })
			nodes.append({ "id": tid, "type": "Transform", "params": {
				"position": [x, 0.0, z], "rotation": [0.0, yaw, 0.0], "scale": [s, s, s] } })
			wires.append({ "from": mid, "out": "node", "to": tid, "in": "node" })
	return { "format": "resonance.arrangement/v1", "name": "optical_showcase",
		"nodes": nodes, "wires": wires }

## Smallest signed angular difference a-b wrapped to [-PI, PI].
func _angle_diff(a: float, b: float) -> float:
	var d := fposmod(a - b + PI, TAU) - PI
	return d

# --- the effect-stack DATA (the renderer-neutral look) ---------------------------------------------

## The CANONICAL effect-stack descriptor for this showcase — pure DATA, the SAME bytes the web delegate
## consumes. [god_rays, lens_flare, bloom]: sunbeams from the canopy gap, a flare off the sun disc, and
## a soft glare bloom. light_screen is filled in at capture from the projected sun (default centre here).
func effect_stack() -> Dictionary:
	return {
		"stack": [
			{ "type": "god_rays", "params": {
				"density": 0.95, "decay": 0.965, "weight": 0.60, "exposure": 0.55,
				"threshold": 0.80, "samples": 64 } },
			{ "type": "lens_flare", "params": {
				"ghosts": 4, "dispersal": 0.28, "halo_width": 0.42, "strength": 0.55,
				"threshold": 0.72 } },
			{ "type": "bloom", "params": { "threshold": 0.75, "intensity": 0.60, "radius": 8 } },
		],
	}

## Project the sun's screen position to a normalized [u,v] (0..1, y-down to match an Image). The sun is
## "at infinity" along -SUN_DIR; we unproject a far point in that direction through the capture camera.
## Returns the frame centre if the sun is behind the camera (so the optical layers degrade gracefully).
func _sun_light_screen() -> Array:
	if _cam == null:
		return [0.5, 0.3]
	if _cam.is_position_behind(SUN_WORLD):
		return [0.5, 0.3]
	var vp_size := _cam.get_viewport().get_visible_rect().size
	if vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return [0.5, 0.3]
	var sp := _cam.unproject_position(SUN_WORLD)
	return [clampf(sp.x / vp_size.x, 0.0, 1.0), clampf(sp.y / vp_size.y, 0.0, 1.0)]

# --- capture: render -> CPU effect stack -> painted still + raw + DATA + manifest --------------------

func _capture() -> void:
	await RenderingServer.frame_post_draw
	var raw := get_viewport().get_texture().get_image()
	var light_screen := _sun_light_screen()
	var desc := effect_stack()
	desc["light_screen"] = light_screen
	# Apply the SAME effect-stack DATA through the CPU reference oracle (the renderer-neutral applier).
	var painted := EffectStackCpu.apply_io(desc, { "color": raw, "light_screen": light_screen })
	var dir := _out_dir if _out_dir != "" else "res://live/convergence"
	_ensure_dir(dir)
	var raw_path := dir + "/godot_forest_optical_raw.png"
	var painted_path := dir + "/godot_forest_optical.png"
	raw.save_png(raw_path)
	painted.save_png(painted_path)
	# Re-write the DATA next to the stills, now with the resolved light_screen, so the web delegate uses
	# the EXACT same descriptor (including the projected sun position).
	_write_effect_data(light_screen, raw.get_width(), raw.get_height())
	print("[optical_showcase] captured: raw=%s painted=%s light_screen=%s" % [
		raw_path, painted_path, str(light_screen)])

## Write the effect-stack DATA (and, when known, the resolved light_screen + frame size) to a JSON file
## the three.js web delegate loads — so both renderers consume byte-identical DATA. Written even in the
## headless smoke run (with the default centre light) so the DATA always exists.
func _write_effect_data(light_screen: Array = [0.5, 0.25], w: int = 0, h: int = 0) -> void:
	var dir := _out_dir if _out_dir != "" else "res://live/convergence"
	_ensure_dir(dir)
	var desc := effect_stack()
	desc["light_screen"] = light_screen
	var payload := {
		"format": "resonance.effect_stack/v1",
		"scene": "optical_showcase (enclosed forest)",
		"frame": { "width": w, "height": h },
		"effect_stack": desc,
	}
	var f := FileAccess.open(dir + "/effect_stack.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()

func _ensure_dir(dir: String) -> void:
	if dir.begins_with("res://") or dir.begins_with("user://"):
		DirAccess.make_dir_recursive_absolute(dir)
	else:
		DirAccess.make_dir_recursive_absolute(dir)

func _parse_out_dir() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			return a.substr(6)
	for a in OS.get_cmdline_args():
		if a.begins_with("--out="):
			return a.substr(6)
	return ""

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()
