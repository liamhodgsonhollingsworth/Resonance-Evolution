extends Node3D
## nature_scene_proof — windowed/headless progress-render driver for the P0 substrate of
## notes/planning/evolving_scene_generator_plan_2026_07_08.md (Wavelet PR #815), [creative-plans-
## lane-2026-07-15] item 9: the plan's own §3 architecture diagram, built for real and captured in
## ONE PNG (the progress image for Alethea-cc/state/discord_outbox_media/):
##
##   TerrainGenerator.build() -- fBm heightfield + normal_detail erosion + constraint field (0.1)
##       |  ground Mesh                              |  constraint_field (slope/moisture/biome)
##       v                                            v
##   MeshInstance3D (the walkable ground)     NatureSceneScatter.scatter() -- REUSES
##                                             ScatterComposer.sample() (Poisson-disk, unedited) +
##                                             LSystem (plant geometry, unedited)
##                                                            |
##                                             GodotSceneRenderer.build_static_tree() (REUSED,
##                                             unedited) instantiates each plant's scene_node
##
## Mirrors ring_scaffold_proof.gd's own proof-render convention exactly (camera/light/env setup,
## `--shot` capture idiom via RenderingServer.frame_post_draw).
##
##   <godot> --path godot res://nature_scene_proof.tscn -- --shot
## writes godot/live/nature_scene_proof.png after a few frames, then quits.

const SHOT_OUT := "res://live/nature_scene_proof.png"
const GLB_OUT := "res://live/nature_scene_terrain.glb"

var _shot_frames := 0

func _ready() -> void:
	_build_env()
	_build_scene()

func _build_env() -> void:
	var cam := Camera3D.new()
	# A 24x24-world-unit terrain (40 cells * 0.6 cell_size) needs real distance to read as a SCENE
	# rather than a close-up thicket -- pulled well back + high, aimed at the terrain's own center.
	var cpos := Vector3(21.0, 17.0, 27.0)
	var look_at := Vector3(11.7, 2.0, 11.7)
	cam.transform = Transform3D(Basis.looking_at(look_at - cpos, Vector3.UP), cpos)
	cam.fov = 60.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -40, 0)
	light.light_energy = 1.15
	light.light_color = Color(1.0, 0.96, 0.88)
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.72, 0.86)  # simple sky-blue -- the standing sky/clouds
	# module is a separate REUSE seam (renderers/sky.gd); this proof stays focused on terrain+scatter.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.7, 0.6)
	env.ambient_light_energy = 0.55
	env_node.environment = env
	add_child(env_node)

## Height/slope/biome -> a simple tinted vertex-color material (cheap, dependency-free — no texture
## asset needed): low+flat reads blue-green (water-adjacent), mid reads grass green, steep reads
## grey rock, high reads pale alpine. Approximated here as a single flat albedo per biome id chosen
## per MeshInstance is overkill for one ground mesh, so this proof instead colors the whole ground
## by its DOMINANT biome (computed from the constraint field) — good enough to make the biome
## classifier's effect legible in one still frame; a per-vertex biome-blended shader is a documented
## follow-up (visuals-lane territory), not built here.
func _material_for_dominant_biome(biome_id: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.9
	match biome_id:
		TerrainGenerator.BIOME_WATER:
			mat.albedo_color = Color(0.30, 0.45, 0.55)
		TerrainGenerator.BIOME_GRASSLAND:
			mat.albedo_color = Color(0.38, 0.55, 0.28)
		TerrainGenerator.BIOME_FOREST:
			mat.albedo_color = Color(0.24, 0.42, 0.22)
		TerrainGenerator.BIOME_ROCK:
			mat.albedo_color = Color(0.5, 0.47, 0.44)
		TerrainGenerator.BIOME_ALPINE:
			mat.albedo_color = Color(0.82, 0.82, 0.85)
		_:
			mat.albedo_color = Color(0.4, 0.5, 0.3)
	return mat

func _dominant_biome(biome_id_field: PackedFloat32Array) -> int:
	var counts := {}
	for v in biome_id_field:
		var b := int(round(v * float(TerrainGenerator.BIOME_COUNT - 1)))
		counts[b] = int(counts.get(b, 0)) + 1
	var best := TerrainGenerator.BIOME_GRASSLAND
	var best_count := -1
	for b in counts.keys():
		if int(counts[b]) > best_count:
			best_count = int(counts[b])
			best = int(b)
	return best

func _build_scene() -> void:
	# A modest-but-real terrain: 40x40 grid, full near/far octave cross-fade (detail_knob=1.0,
	# uniform falloff -- so the WHOLE terrain gets the fine octaves, legible at proof-render scale),
	# normal_detail erosion smoothing the result.
	var terrain := TerrainGenerator.build({
		"width": 40, "depth": 40, "cell_size": 0.6, "seed": 2026,
		"base_octaves": 3, "extra_octaves": 3, "amplitude": 4.5, "noise_scale": 0.09,
		"detail_knob": 1.0, "falloff": {"type": "uniform"},
		"erosion": {"method": "normal_detail", "strength": 0.4, "iterations": 3},
	})

	var ground := MeshInstance3D.new()
	ground.name = "terrain_ground"
	ground.mesh = terrain["mesh"]
	var cf: Dictionary = terrain["constraint_field"]
	ground.material_override = _material_for_dominant_biome(_dominant_biome(cf["biome_id"]))
	add_child(ground)

	# Exercise the real GLB export path on this same terrain (a live smoke check alongside the
	# headless unit test) -- writes into the gitignored godot/live/ tree, not committed.
	var export_err := TerrainGenerator.export_glb(terrain["mesh"], GLB_OUT, "NatureSceneTerrain")

	# Scatter plants across the terrain's own constraint field -- the closed loop: Terrain ->
	# Constraint Field -> Scatter (REUSED ScatterComposer) -> CALL@LSystem (REUSED LSystem).
	var placements := NatureSceneScatter.scatter(terrain, {
		"seed": 2026, "density": 0.5, "min_dist": 2.4, "max_slope": 0.5,
		"size_min": 0.5, "size_max": 0.95,
	})
	var placed_count := 0
	for p in placements:
		if p["scene_node"] == null:
			continue  # an unresolved CC0/rock asset-seam handle -- nothing to instantiate yet
		var holder := Node3D.new()
		holder.transform = p["transform"]
		var scale: float = p.get("scale", 1.0)
		holder.scale = Vector3.ONE * scale
		add_child(holder)
		GodotSceneRenderer.build_static_tree([p["scene_node"]], holder)
		placed_count += 1

	print("[nature_scene_proof] terrain 40x40 (dominant biome=%d), %d/%d plant placements instantiated, GLB export err=%d -> %s" %
		[_dominant_biome(cf["biome_id"]), placed_count, placements.size(), export_err, GLB_OUT])

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(SHOT_OUT)
		print("[nature_scene_proof] captured -> ", SHOT_OUT)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
