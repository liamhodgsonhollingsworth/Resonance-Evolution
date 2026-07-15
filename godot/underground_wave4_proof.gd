extends Node3D
## underground_wave4_proof -- windowed progress-render + REFERENCE-CAMERA-SCORED driver for Wave 4
## item 4.1 (AmberLightCubeScatterer, RoofGlowCutoff, AtmosphericFogVolume), DQ-60f088f7. Composes
## every already-merged Wave 1-3 primitive (RingScaffoldGenerator, NonOverlappingCavityCarver,
## ProceduralRockTexture, ReflectiveFloorMaterial -- ScatterComposer transitively, via both) with the
## THREE new Wave 4 nodes, scored against the "underground_halls" reference image (Alethea-cc/tools/
## image_evolver/reference_camera_score.py, PR #895) via a CLOSED-LOOP aesthetic-iteration pass
## (4 iterations; scores 0.4597 -> 0.4716 -> 0.4836 -> 0.4828 -- iteration 3 is the kept best,
## committed as wave4_best_tunables.json (see TUNABLES lookup below); iteration 4 tried pushing the
## amber hue further toward gold and plateaued/slightly regressed, confirming 3 as a local optimum
## for this direction). Renders + iteration notes: Alethea-cc/state/discord_outbox_media/underground/.
##
## Liam's two AESTHETIC-CRITICAL elements, both wired here: amber light cubes ON WALLS (Poisson-disk,
## via AmberLightCubeScatterer.scatter_wall) AND INSIDE every carved cavity (niches + through-
## passages both, via scatter_cavities); a bright roof glow above a tunable elevation (RoofGlowCutoff,
## composed as an ADDITIVE next_pass overlay on the real rock-texture wall material, never replacing
## it). AtmosphericFogVolume adds tunable distance mist on the same WorldEnvironment. The wall
## material itself uses ProceduralRockTexture's "sandstone" palette (not Wave 3's own "slate") --
## the reference image's rock is a warm carved-orange tone; this was the single biggest color-match
## lever found during iteration.
##
## GEOMETRY NOTE (the thing that took several iterations to get right): wall_surface_uv() is
## explicitly the ring's INNER shell surface -- "what a person WALKING THE HALLWAY sees" -- i.e. the
## surface facing the tube's own hollow corridor interior, NOT the plaza at the world center. Every
## amber cube sits on that surface. The camera below is therefore positioned INSIDE ring 1's own
## tube (computed off the actual _shell_extents math, not guessed), looking along the ring's tangent
## direction -- a camera in the central plaza is on the wrong side of the wall and sees no cubes.
##
## Tunables for the three Wave 4 nodes are read, in priority order: (1) `res://live/wave4_tunables.json`
## if present (gitignored -- godot/.gitignore's `/live/*` -- what a live iteration pass writes fresh
## each run); (2) `res://wave4_best_tunables.json` (COMMITTED -- the iteration-3 winning config,
## reproduces the kept-best render on a fresh checkout with no live JSON); (3) each module's own
## documented defaults. JSON shape: {"amber": {...}, "roof": {...}, "fog": {...}}; colors are
## [r,g,b] or [r,g,b,a] arrays.
##
##   <godot> --path godot res://underground_wave4_proof.tscn -- --shot
##     writes godot/live/underground_wave4_proof.png at the scored establishing-shot pose.
##   <godot> --path godot res://underground_wave4_proof.tscn -- --shot --detail
##     writes godot/live/underground_wave4_proof_detail.png -- a close framing on a wall segment
##     showing the amber cubes + roof glow at a legible scale (unscored, for human review).

const SHOT_OUT_WIDE := "res://live/underground_wave4_proof.png"
const SHOT_OUT_DETAIL := "res://live/underground_wave4_proof_detail.png"
const LIVE_TUNABLES_PATH := "res://live/wave4_tunables.json"
const BEST_TUNABLES_PATH := "res://wave4_best_tunables.json"

var _shot_frames := 0
var _detail_mode := false
var _shot_out := SHOT_OUT_WIDE
var _tunables: Dictionary = {}

func _ready() -> void:
	_detail_mode = "--detail" in OS.get_cmdline_user_args() or "--detail" in OS.get_cmdline_args()
	_shot_out = SHOT_OUT_DETAIL if _detail_mode else SHOT_OUT_WIDE
	_tunables = _load_tunables()
	_build_scene()

func _load_tunables() -> Dictionary:
	for path in [LIVE_TUNABLES_PATH, BEST_TUNABLES_PATH]:
		var d := _load_json_dict(path)
		if not d.is_empty():
			return d
	return {}

func _load_json_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

func _color_from_json(v, fallback: Color) -> Color:
	if v is Array and v.size() >= 3:
		var a: float = float(v[3]) if v.size() > 3 else 1.0
		return Color(float(v[0]), float(v[1]), float(v[2]), a)
	return fallback

func _build_env() -> Environment:
	var cam := Camera3D.new()
	# CRITICAL geometry note: wall_surface_uv() (ring_scaffold.gd) is explicitly the ring's INNER
	# shell surface -- "the corridor-interior-facing boundary... what a person WALKING THE HALLWAY
	# sees" -- i.e. the surface facing INTO the tube's own hollow interior, NOT the surface facing the
	# open plaza at the world center. AmberLightCubeScatterer places every cube on that same surface
	# (protruding along its +Z, into the corridor). A camera standing in the central plaza (world
	# radius near 0) is on the WRONG side of the wall material entirely -- it can see the rock
	# texture (both shell faces render) but every amber cube is hidden on the far side, inside the
	# tube. The camera must stand INSIDE ring 1's own tube (world radius ~= radius_start) to see the
	# hallway -- and its cavities/cubes -- "from inside", which is also the actual "underground HALLS"
	# read the reference image itself is going for.
	if _detail_mode:
		# Inside ring 1's tube near angle a=0 (world position ~(radius_start, y, 0)), close on the
		# near wall segment -- the framing that sells the amber cubes + rock texture at a legible
		# scale.
		var cpos := Vector3(6.6, -2.0, 1.2)
		var target := Vector3(7.6, -0.8, -3.5)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 55.0
	else:
		# Registered as "underground_halls_wave4" in the reference-camera pose registry (a sibling of
		# "underground_halls_default", both score against the SAME "underground_halls" reference
		# image). Standing INSIDE ring 1's tube, near-floor height, looking along the corridor's own
		# tangent direction (curving away into ring 1's loop) with a slight upward tilt so the SAME
		# single establishing shot carries all three Wave 4 elements at once: wall-embedded + cavity
		# amber cubes lining both sides, the reflective floor underfoot, and the roof glow arching
		# overhead as the corridor curves into the distance -- the composition the closed-loop
		# fitness-scoring iteration actually judges.
		# Computed off the actual ring geometry (radius_start=9, gap=6 -> hw_inner=2.7, hh_inner=3.6,
		# per _shell_extents' own math) rather than guessed: a point ~8deg into wedge arc 0 (clear of
		# the arc-0/arc-N seam), radially centered, near-floor height, looking along the ring's OWN
		# tangent direction (the direction a person walking this corridor would face) with a mild
		# upward tilt -- so the shot reads as standing inside the hallway looking down its own curve,
		# not a guessed straight-line framing that clips through the tube wall.
		var cpos := Vector3(8.912, -1.98, 1.253)
		var target := Vector3(10.165, -1.48, -7.660)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 65.0
	add_child(cam)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -40, 0)
	light.light_energy = 1.1
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(2.0, 3.0, -6.0)
	fill.light_energy = 3.0
	fill.omni_range = 18.0
	fill.light_color = Color(1.0, 0.85, 0.6)
	add_child(fill)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.36, 0.3)
	env.ambient_light_energy = 0.55
	var env_node := WorldEnvironment.new()
	env_node.environment = env
	add_child(env_node)
	return env

func _build_scene() -> void:
	var ring_count := 3
	# Wider gap/radius_start than the Wave 3 proof scenes -- the reference-camera pose sits at world
	# ORIGIN (the open plaza before ring 1's near wall, per RingScaffoldGenerator's own non-degenerate
	# packing invariant radius_start >= hw_outer). A narrow gap/small radius_start puts that wall only
	# ~1-2m away, an extreme macro close-up that neither shows the amber cubes at a legible scale nor
	# leaves room for the roof glow / fog to read. gap=6.0 (still within the plan's 1-8m range) + a
	# larger radius_start gives the fixed pose real middle-distance breathing room.
	var gap := 6.0
	var radius_start := 9.0
	var segment_arc_deg := 16.0

	var env := _build_env()

	var topo := RingScaffoldGenerator.build_topology(ring_count, radius_start, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)

	var carve_result := NonOverlappingCavityCarver.carve(topo, wall_by_ring,
		{"shape": "mix", "min_spacing": 1.6, "density": 0.9, "depth": 1.0, "seed": 2026,
		"cavity_size": 0.85, "max_carve_depth": 1.6})
	var instances: Array = carve_result["cavity_instances"]

	# Wave 3 node 3: rock wall material, ONE shared instance across every wedge (batches). "sandstone"
	# (not wave3's own "slate") -- the "underground_halls" reference image's own rock is a warm
	# orange/brown carved-earth tone, which the amber cubes then punctuate as small glowing accents,
	# exactly the palette-by-handle relink TextureSynthCpu's PALETTES registry exists for (no new
	# texture code, just a different handle).
	var rock_mat := ProceduralRockTexture.build_material(
		{"noise_seed": 4177, "noise_scale": 6.0, "palette_handle": "sandstone"}, wall_by_ring.get(1, {}))

	# Wave 4 node B: RoofGlowCutoff, an ADDITIVE next_pass overlay on the SAME rock_mat -- the real
	# rock texture renders completely untouched below the cutoff; the overlay pass only ever ADDS
	# glow above it.
	var roof_t: Dictionary = _tunables.get("roof", {})
	RoofGlowCutoff.apply_as_overlay(rock_mat, {
		"cutoff_elevation": float(roof_t.get("cutoff_elevation", RoofGlowCutoff.DEFAULT_CUTOFF_ELEVATION)),
		"glow_color": _color_from_json(roof_t.get("glow_color"), RoofGlowCutoff.DEFAULT_GLOW_COLOR),
		"glow_energy": float(roof_t.get("glow_energy", RoofGlowCutoff.DEFAULT_GLOW_ENERGY)),
		"blend_softness": float(roof_t.get("blend_softness", RoofGlowCutoff.DEFAULT_BLEND_SOFTNESS)),
	})

	# Wave 3 node 4: reflective floor.
	var floor_result := ReflectiveFloorMaterial.build(
		{"base_color": Color(0.08, 0.09, 0.12), "gloss": 0.85, "reflection_mode": "ssr"})
	var floor_mat: StandardMaterial3D = floor_result["material"]
	ReflectiveFloorMaterial.apply_environment(env, floor_result["environment_patch"])

	# Wave 4 node C: fog/mist -- composes onto the SAME Environment (different fields than SSR, no
	# conflict).
	var fog_t: Dictionary = _tunables.get("fog", {})
	AtmosphericFogVolume.apply_environment(env, AtmosphericFogVolume.build_environment_patch({
		"density": float(fog_t.get("density", AtmosphericFogVolume.DEFAULT_DENSITY)),
		"color": _color_from_json(fog_t.get("color"), AtmosphericFogVolume.DEFAULT_COLOR),
		"height": float(fog_t.get("height", AtmosphericFogVolume.DEFAULT_HEIGHT)),
		"height_density": float(fog_t.get("height_density", AtmosphericFogVolume.DEFAULT_HEIGHT_DENSITY)),
		"sun_scatter": float(fog_t.get("sun_scatter", AtmosphericFogVolume.DEFAULT_SUN_SCATTER)),
	}))

	var hh_outer := (gap * 0.5) * RingScaffoldGenerator.DEFAULT_ELLIPSE_RATIO
	var floor_y := -hh_outer - 0.05
	var outer_radius: float = radius_start + gap * float(ring_count - 1) + gap * 0.6
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(outer_radius * 2.2, 0.1, outer_radius * 2.2)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = floor_mat
	floor_mi.position = Vector3(0.0, floor_y - 0.05, 0.0)
	add_child(floor_mi)

	var built_chunks := 0
	for ring_data in topo:
		var chunks := RingScaffoldGenerator.wedge_chunks([ring_data], segment_arc_deg, gap)
		for chunk in chunks:
			var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = rock_mat
			add_child(mi)
			built_chunks += 1

	# Every carved cavity (niche AND through-passage) gets its own recess/tunnel geometry instanced
	# with a plain dark material -- the AMBER CUBE (below) is what supplies the "glowing" accent, not
	# the cavity wall material itself.
	var cavity_wall_mat := StandardMaterial3D.new()
	cavity_wall_mat.albedo_color = Color(0.18, 0.12, 0.08)
	cavity_wall_mat.roughness = 0.9

	var niche_count := 0
	var through_count := 0
	for inst in instances:
		var mesh: Mesh = inst["mesh"]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = cavity_wall_mat
		add_child(mi)
		if inst["through"]:
			through_count += 1
		else:
			niche_count += 1

	# Wave 4 node A: AmberLightCubeScatterer -- ON WALLS (per-ring Poisson-disk) AND INSIDE CAVITIES
	# (every carved niche/through-passage), per Liam's "on walls AND inside cavities" spec.
	# AESTHETIC-CRITICAL: hue/emission/density here drive the whole image's composing "vibe".
	var amber_t: Dictionary = _tunables.get("amber", {})
	var amber_tunables := {
		"density": float(amber_t.get("density", AmberLightCubeScatterer.DEFAULT_DENSITY)),
		"min_spacing": float(amber_t.get("min_spacing", AmberLightCubeScatterer.DEFAULT_MIN_SPACING)),
		"size_min": float(amber_t.get("size_min", AmberLightCubeScatterer.DEFAULT_SIZE_MIN)),
		"size_max": float(amber_t.get("size_max", AmberLightCubeScatterer.DEFAULT_SIZE_MAX)),
		"hue": float(amber_t.get("hue", AmberLightCubeScatterer.DEFAULT_HUE)),
		"hue_jitter": float(amber_t.get("hue_jitter", AmberLightCubeScatterer.DEFAULT_HUE_JITTER)),
		"saturation": float(amber_t.get("saturation", AmberLightCubeScatterer.DEFAULT_SATURATION)),
		"value": float(amber_t.get("value", AmberLightCubeScatterer.DEFAULT_VALUE)),
		"emission_energy": float(amber_t.get("emission_energy", AmberLightCubeScatterer.DEFAULT_EMISSION_ENERGY)),
		"glass_alpha": float(amber_t.get("glass_alpha", AmberLightCubeScatterer.DEFAULT_GLASS_ALPHA)),
		"cavity_fill_probability": float(amber_t.get("cavity_fill_probability", AmberLightCubeScatterer.DEFAULT_CAVITY_FILL_PROBABILITY)),
		"protrusion": float(amber_t.get("protrusion", AmberLightCubeScatterer.DEFAULT_PROTRUSION)),
		"seed": int(amber_t.get("seed", 2026)),
	}

	var cube_count := 0
	for ring_data in topo:
		var ring_index := int(ring_data["ring"])
		var wall_uv: Dictionary = wall_by_ring.get(ring_index, {})
		var placements := AmberLightCubeScatterer.scatter_wall(wall_uv, amber_tunables)
		cube_count += _instance_cubes(placements, amber_tunables)
	var cavity_placements := AmberLightCubeScatterer.scatter_cavities(instances, amber_tunables)
	cube_count += _instance_cubes(cavity_placements, amber_tunables)

	print("[underground_wave4_proof] built %d wedges; carved %d niches + %d through-passages; placed %d amber light cubes; floor y=%.2f fog_density=%.3f roof_cutoff=%.2f" %
		[built_chunks, niche_count, through_count, cube_count, floor_y,
		env.fog_density, float(roof_t.get("cutoff_elevation", RoofGlowCutoff.DEFAULT_CUTOFF_ELEVATION))])

func _instance_cubes(placements: Array, amber_tunables: Dictionary) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(amber_tunables.get("seed", 2026)) + 777
	var n := 0
	for p in placements:
		var mi := MeshInstance3D.new()
		mi.mesh = p["mesh"]
		mi.material_override = AmberLightCubeScatterer.jittered_material(amber_tunables, rng)
		mi.transform = p["transform"]
		add_child(mi)
		n += 1
	return n

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_shot_out)
		print("[underground_wave4_proof] captured -> ", _shot_out)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
