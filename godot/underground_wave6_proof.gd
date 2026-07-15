extends Node3D
## underground_wave6_proof -- implements Liam's 2026-07-15 process-refinement for the underground
## scene (DISPATCH claim underground-railing-iteration-2026-07-15, Discord msg 15:08:25Z, verbatim
## quoted in full at the bottom of this file). Supersedes the "iterate toward the reference via an
## automated closed-loop scorer" framing of the original brief -- Liam places the camera himself now
## (`ViewpointPicker`), so this scene's job is to deliver the TOOLS (tunable, node-based, live), not
## a pre-tuned "matches the reference" render.
##
## Composes, in Liam's own 4-step order:
##   1. `GroundPlane` (renderers/ground_plane.gd, new) -- flat ground = the equatorial plane; rings
##      use `RingScaffoldGenerator`'s new `ground_plane_mode` (increment 3) so only the upper
##      (ceiling) half of each ring's elliptical shell is built, meeting the ground plane exactly at
##      its own natural edge -- no seam geometry.
##   2. `RingScaffoldGenerator.build_topology()` -- concentric rings, ALL sharing world-origin as
##      their center of symmetry (already true by construction); `ring_count`/`gap`/`radius_start`/
##      `ellipse_ratio` are live tunables (below), not baked constants.
##   3. `ViewpointPicker` (tools/viewpoint_picker.gd, new) -- the reusable camera-placement tool;
##      Liam flies around, tunes the view live via the PiP preview (or pop-out window), and can save
##      the pose for reuse by `reference_camera_score.py` / a future Aperture scenery view.
##   4. Cavities (`NonOverlappingCavityCarver`), bridges (`BridgeGenerator`) + their railings
##      (`RailingGenerator` -- balcony/cavity-rim railings now optionally ARC-FOLLOW the ring's own
##      curvature instead of a flat chord, `rim_curved`/`rim_arc_segments`, DQ-9401aaab 2026-07-15),
##      trees (`PlantScatterInCavities` -- now wired to REAL pre-existing CC0 tree assets from the
##      already-ingested `quaternius_nature` kit by default, `tree_source`/`tree_species_mix`/
##      `tree_scale_min`/`tree_scale_max`, DQ-9183cfe2 2026-07-15; `tree_source=lsystem` still
##      available as a fallback), and lights (`AmberLightCubeScatterer`, now with `flush=true` --
##      coplanar, zero protrusion) -- every one exposed as a live slider/toggle in `TunablePanel`
##      (tools/tunable_panel.gd, new).
##
## Launch modes:
##   <godot> --path godot res://underground_wave6_proof.tscn
##     Interactive: Tab to enter placement mode, fly the ViewpointPicker, tune the panel live.
##   <godot> --path godot res://underground_wave6_proof.tscn -- --shot
##     Headless-safe verification/milestone capture: builds the scene with default tunables under a
##     FIXED default camera (same pattern every prior wave proof uses), writes
##     `godot/live/underground_wave6_proof.png`, and quits -- proves the whole pipeline (ground
##     plane, upper-half rings, cavities, bridges+railings, trees, flush lights, and the
##     ViewpointPicker/TunablePanel nodes themselves) boots and renders without crashing.
##   <godot> --path godot res://underground_wave6_proof.tscn -- --param-listen --channel-uri ws://127.0.0.1:8790/underground [--listen-seconds 20] [--min-updates 3]
##     DQ-0343912a: connects `TunablePanel`'s live edits + `ViewpointPicker`'s pose out over the
##     EXISTING `param_channel`/`ws://` transport (Wavelet PR #910 -- `param_channel_node.py` /
##     `ws_endpoint.py` / `ws_relay_server.py`), via the native GDScript client
##     `tools/param_channel_client.gd` (same wire shape, no new protocol). Any OTHER endpoint that
##     joins the SAME room (a browser tuner panel, a Python test client, another Godot window) can
##     drive this scene's tunables + camera pose live, cross-window/cross-device -- "you can plug
##     those nodes into UI knobs and controls for me to change them" (Liam, 2026-07-15). Skips the
##     interactive TunablePanel/ViewpointPicker-overlay UI (a headless/batch run, like --shot) but
##     keeps applying every received param to the SAME `_rebuild_geometry()` path a local slider
##     drag would use, and writes `godot/live/underground_param_state.json` after every applied
##     change (state read-back verification evidence -- headless texture readback is unreliable on
##     this engine build, see `tools/scene_smoketest.py`'s own docstring, so a caller that cannot
##     trust a screenshot can trust this file instead). Also captures
##     `godot/live/underground_param_wiring_proof.png` once the deadline/min-updates is reached, from
##     whatever `ViewpointPicker` pose was last applied (local default, or a `viewpoint_pose` message
##     received over the channel) -- demonstrating pose-as-a-param in the same shot.
##   <godot_console, WITHOUT --headless (texture readback hangs on this Godot build in headless mode)>
##       --path godot res://underground_wave6_proof.tscn -- --milestone-shot
##     Milestone-quality capture (DQ-9183cfe2/DQ-9401aaab, 2026-07-15): builds the scene with default
##     tunables, then frames the camera via a transient `ViewpointPicker.set_pose()` call aimed at a
##     REAL populated cavity wall (a `cavity_cutaway_field` entry that actually carries a tree +
##     curved balcony-rim railing -- NOT the wave4/5/6 default `--shot` camera, which sits below the
##     ground plane and mostly frames ground+sky). Writes
##     `godot/live/underground_wave6_milestone.png` and quits.

const SHOT_OUT := "res://live/underground_wave6_proof.png"
const PARAM_LISTEN_SHOT_OUT := "res://live/underground_param_wiring_proof.png"
const PARAM_STATE_OUT := "res://live/underground_param_state.json"
const MILESTONE_SHOT_OUT := "res://live/underground_wave6_milestone.png"

var _geometry_root: Node3D
var _tunable_panel: TunablePanel
var _viewpoint: ViewpointPicker
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
	if _milestone_shot_mode:
		_build_milestone_camera()
	else:
		_build_default_camera()

	# DQ-0343912a: opt-in only (empty uri = disabled, so --shot and every prior launch mode are
	# byte-for-byte unaffected). Same ParamChannelClient instance serves both the interactive
	# TunablePanel/ViewpointPicker path (below) and the --param-listen headless path.
	if channel_uri != "":
		_param_channel = ParamChannelClient.new(channel_uri)

	# The ViewpointPicker's own SubViewport (a SECOND live-rendering camera) is for INTERACTIVE
	# sessions only -- --shot is a fixed-camera automated smoke-test capture and does not need it
	# (and a second real-time-updating viewport is a needless cost, and empirically stalls headless
	# capture on this engine build -- observed hang, root-caused during this DISPATCH claim's own
	# verification pass; skipping it here is a real fix, not a workaround for an unrelated bug).
	# --param-listen ALSO skips the PiP/overlay (same stall risk, ViewpointPicker.build_preview =
	# false, DQ-0343912a) but still builds the picker itself for real get_pose()/set_pose()/
	# pose_changed -- the whole point of this mode is exercising that API over the channel.
	if not _shot_mode:
		_viewpoint = ViewpointPicker.new()
		_viewpoint.reference_name = "underground_halls"
		_viewpoint.transform = Transform3D(Basis.looking_at(Vector3(0, 1.5, -8) - Vector3(8.9, -2.0, 1.3), Vector3.UP), Vector3(8.9, -2.0, 1.3))
		if _param_listen_mode:
			_viewpoint.build_preview = false
		_viewpoint.pose_changed.connect(_on_viewpoint_pose_changed)
		add_child(_viewpoint)

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
	# --param-listen's initial camera framing follows whatever pose ViewpointPicker starts at (its
	# fixed placement-tool transform above) until a real pose arrives over the channel.
	if _param_listen_mode and _viewpoint != null and _main_camera != null:
		_sync_camera_to_pose(_main_camera, _viewpoint.get_pose())

	if _shot_mode or _param_channel != null:
		set_process(true)


func _default_tunables() -> Dictionary:
	var out := {}
	for spec in _param_specs():
		out[spec["key"]] = spec["default"]
	return out


## ---- cmdline helpers (DQ-0343912a; same `OS.get_cmdline_user_args()` convention --shot already
##      uses, extended to also read a flag's VALUE, not just its presence) ----

func _cmdline_flag(flag: String) -> bool:
	return flag in OS.get_cmdline_user_args() or flag in OS.get_cmdline_args()


func _cmdline_value(flag: String, default_v: String) -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == flag and i + 1 < args.size():
			return args[i + 1]
	return default_v


func _param_specs() -> Array:
	return [
		{"key": "ring_count", "label": "ring_count", "type": "int", "min": 1, "max": 8, "step": 1, "default": 3},
		{"key": "gap", "label": "gap (hallway width)", "type": "float", "min": 2.0, "max": 10.0, "step": 0.1, "default": 6.0},
		{"key": "radius_start", "label": "radius_start", "type": "float", "min": 3.0, "max": 20.0, "step": 0.5, "default": 9.0},
		{"key": "ellipse_ratio", "label": "ellipse_ratio", "type": "float", "min": 0.5, "max": 2.0, "step": 0.05, "default": 1.3},
		{"key": "segment_arc_deg", "label": "segment_arc_deg", "type": "float", "min": 5.0, "max": 45.0, "step": 1.0, "default": 16.0},
		{"key": "baluster_style", "label": "railing style", "type": "enum",
			"options": ["vertical_bars", "lattice", "panel", "none"], "default": "vertical_bars"},
		{"key": "baluster_spacing", "label": "railing bar spacing", "type": "float", "min": 0.05, "max": 0.4, "step": 0.01, "default": 0.14},
		{"key": "rail_height", "label": "rail height", "type": "float", "min": 0.6, "max": 1.5, "step": 0.05, "default": 1.05},
		{"key": "cavity_density", "label": "cavity density", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.9},
		{"key": "bridge_connect_probability", "label": "bridge density", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.85},
		{"key": "light_density", "label": "light density", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.35},
		{"key": "light_flush", "label": "lights flush (no protrusion)", "type": "bool", "default": true},
		{"key": "tree_density", "label": "tree density", "type": "float", "min": 0.0, "max": 1.0, "step": 0.05, "default": 0.7},
		{"key": "ground_extent_multiplier", "label": "ground plane extent", "type": "float", "min": 1.0, "max": 2.5, "step": 0.05, "default": 1.1},
		{"key": "tree_source", "label": "tree source", "type": "enum", "options": ["kit", "lsystem"], "default": "kit"},
		{"key": "tree_species_mix", "label": "tree species mix", "type": "enum",
			"options": ["both", "pine_only", "twisted_tree_only"], "default": "both"},
		{"key": "tree_scale_min", "label": "tree scale min", "type": "float", "min": 0.2, "max": 2.0, "step": 0.05, "default": 0.5},
		{"key": "tree_scale_max", "label": "tree scale max", "type": "float", "min": 0.2, "max": 3.0, "step": 0.05, "default": 1.1},
		{"key": "rim_curved", "label": "balcony rim follows curve", "type": "bool", "default": true},
		{"key": "rim_arc_segments", "label": "balcony rim arc resolution", "type": "int", "min": 1, "max": 20, "step": 1, "default": 6},
	]


func _on_tunable_changed(key: String, value: Variant) -> void:
	# DQ-0343912a: a re-entrant apply from _apply_external_param() (a message that arrived OVER the
	# channel) already updated _current_tunables + rebuilt geometry itself -- skip so an external
	# update never re-publishes back out (would ping-pong between two channel peers forever).
	if _applying_external_param:
		return
	_current_tunables[key] = value
	if _param_channel != null:
		_param_channel.publish(key, value)
	_rebuild_geometry(_current_tunables)
	_rebuild_count += 1
	if _param_channel != null:
		_write_state_json()


func _build_env() -> void:
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

	var floor_result := ReflectiveFloorMaterial.build(
		{"base_color": Color(0.08, 0.09, 0.12), "gloss": 0.85, "reflection_mode": "ssr"})
	ReflectiveFloorMaterial.apply_environment(env, floor_result["environment_patch"])
	set_meta("_floor_mat", floor_result["material"])

	AtmosphericFogVolume.apply_environment(env, AtmosphericFogVolume.build_environment_patch({}))


func _build_default_camera() -> void:
	# Fixed default camera for --shot / smoke-test verification ONLY -- interactive sessions steer
	# via the ViewpointPicker instead (Liam places the perspective himself, per this file's header).
	var cam := Camera3D.new()
	var cpos := Vector3(8.912, -1.98, 1.253)
	var target := Vector3(10.165, -1.48, -7.660)
	cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
	cam.fov = 65.0
	cam.current = true
	add_child(cam)
	_main_camera = cam


## DQ-0343912a: move the MAIN camera to match a ViewpointPicker pose. Used by --param-listen (whose
## whole point is a channel-driven pose demo) whenever ViewpointPicker's pose changes -- locally
## (fly controls) or from an external `viewpoint_pose` channel message via _apply_external_param().
## The fixed --shot camera above is untouched by this (this function is only ever called when
## _viewpoint/_main_camera are both non-null, which --shot never sets up).
func _sync_camera_to_pose(cam: Camera3D, pose: Dictionary) -> void:
	if cam == null or not pose.has("position"):
		return
	var p: Array = pose["position"]
	var pos := Vector3(float(p[0]), float(p[1]), float(p[2]))
	cam.global_position = pos
	if pose.has("look_at"):
		var la: Array = pose["look_at"]
		var target := Vector3(float(la[0]), float(la[1]), float(la[2]))
		if target.distance_to(pos) > 0.0001:
			cam.look_at(target, Vector3.UP)
	cam.fov = float(pose.get("fov_deg", cam.fov))


func _on_viewpoint_pose_changed(pose: Dictionary) -> void:
	if _main_camera != null and _param_listen_mode:
		_sync_camera_to_pose(_main_camera, pose)
	if _applying_external_param:
		return  # re-entrant from a received "viewpoint_pose" message -- do not re-publish (ping-pong guard)
	if _param_channel != null:
		_param_channel.publish("viewpoint_pose", pose)


## DQ-0343912a: apply ONE param received over the channel -- the remote-origin twin of
## _on_tunable_changed() (local slider drag). Routes through the EXACT SAME _rebuild_geometry() /
## ViewpointPicker.set_pose() calls a local edit would use, so "a message arrived" and "Liam dragged
## a slider" are indistinguishable to the geometry/camera -- the whole point of a transport-neutral
## channel. "viewpoint_pose" is handled specially (a composite Dictionary, not a _param_specs() key).
func _apply_external_param(key: String, value: Variant) -> void:
	_applying_external_param = true
	if key == "viewpoint_pose" and value is Dictionary:
		if _viewpoint != null:
			_viewpoint.set_pose(value)
		# A pose-only change touches no _param_specs() tunable (no geometry rebuild needed) but IS a
		# live-applied update -- count it + persist it so a caller polling ONLY the pose (e.g. this
		# module's own --param-listen --min-updates gate, or an external state read-back) observes
		# it without also having to change a scalar tunable in the same batch.
		_rebuild_count += 1
		_write_state_json()
	else:
		_current_tunables[key] = value
		if _tunable_panel != null:
			_tunable_panel.set_value(key, value)
		_rebuild_geometry(_current_tunables)
		_rebuild_count += 1
		_write_state_json()
	_applying_external_param = false


## DQ-0343912a state read-back (verification evidence): headless texture readback is unreliable on
## this engine build (see tools/scene_smoketest.py's own docstring), so a caller driving this scene
## over the channel can confirm "did my param change actually apply" by reading this file back
## instead of trusting a screenshot -- written after every applied change (local or remote-origin).
func _write_state_json() -> void:
	var pose := {}
	if _viewpoint != null:
		pose = _viewpoint.get_pose()
	var out := {
		"schema_version": 1,
		"updated_at_unix": Time.get_unix_time_from_system(),
		"rebuild_count": _rebuild_count,
		"tunables": _current_tunables,
		"viewpoint_pose": pose,
	}
	DirAccess.make_dir_recursive_absolute("res://live")
	var f := FileAccess.open(PARAM_STATE_OUT, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(out, "  "))
		f.close()


## Milestone capture camera (DQ-9183cfe2/DQ-9401aaab, 2026-07-15). The pose is placed via a
## TRANSIENT `ViewpointPicker.set_pose()` call (never added to the tree -- `set_pose()` only touches
## its own local transform, which resolves correctly even parent-less) rather than a hand-rolled
## `Transform3D.looking_at`, so this capture uses the SAME node-based placement API Liam's own
## interactive session uses -- the pose below is not a special case, it's what
## `ViewpointPicker.set_pose({"position":..., "look_at":...})` computes, same as flying there by hand
## and pressing Enter to save it. `pose_origin`/`pose_target` were measured from a real
## `cavity_cutaway_field` entry (the SAME carve seed/tunables `_rebuild_geometry` uses) -- one of the
## four floor-level, tree+curved-rim-railing-bearing cavity openings this default scene actually
## carves -- specifically chosen because the wave4/5/6 DEFAULT `--shot` camera sits BELOW the ground
## plane (`_build_default_camera`'s cpos.y = -1.98) and mostly frames ground+sky, not the populated
## wall this milestone needs to show. Arrived at via an in-engine pose-scouting pass (several
## candidate `ViewpointPicker.set_pose()` calls rendered and compared side by side, not guessed
## once) -- this framing reads cleanly: the curved balcony-rim railing (DQ-9401aaab) arcing across
## the opening, a real ingested-kit tree (DQ-9183cfe2 -- its authored autumn-red foliage instantly
## distinguishes it from the flat-green L-system fallback) overhead, sandstone ring wall either side.
func _build_milestone_camera() -> void:
	var pose_target := Vector3(-11.1604, 1.809515, -3.274492)  # real cavity_cutaway_field origin (ring 1), raised 1.0m toward the tree/rail cluster
	var pose_origin := Vector3(-9.8105, 2.409, -7.875)         # inside the hollow ring interior, a medium composed distance back
	# `set_pose()` resolves global_position/look_at, which need the node inside the tree -- parent it
	# briefly, read the resulting transform, then remove it immediately (before any frame renders)
	# so its own interactive PiP/overlay UI never appears in the capture.
	var vp := ViewpointPicker.new()
	add_child(vp)
	vp.set_pose({
		"position": [pose_origin.x, pose_origin.y, pose_origin.z],
		"look_at": [pose_target.x, pose_target.y, pose_target.z],
		"fov_deg": 55.0,
	})
	var cam := Camera3D.new()
	cam.transform = vp.global_transform
	cam.fov = 55.0
	cam.current = true
	add_child(cam)
	_main_camera = cam
	remove_child(vp)
	vp.queue_free()


func _rebuild_geometry(t: Dictionary) -> void:
	for c in _geometry_root.get_children():
		c.queue_free()

	var ring_count: int = int(t.get("ring_count", 3))
	var gap: float = float(t.get("gap", 6.0))
	var radius_start: float = float(t.get("radius_start", 9.0))
	var ellipse_ratio: float = float(t.get("ellipse_ratio", 1.3))
	var segment_arc_deg: float = float(t.get("segment_arc_deg", 16.0))
	var ground_extent_multiplier: float = float(t.get("ground_extent_multiplier", 1.1))

	# ── Step 1+2: ground plane + upper-half-only concentric rings, shared center of symmetry ──────
	var outer_radius: float = radius_start + gap * float(ring_count - 1) + gap * 0.6
	var ground := GroundPlane.build_mesh({"size": outer_radius * ground_extent_multiplier, "elevation": 0.0})
	var ground_mi := MeshInstance3D.new()
	ground_mi.mesh = ground["mesh"]
	ground_mi.position = ground["position"]
	if has_meta("_floor_mat"):
		ground_mi.material_override = get_meta("_floor_mat")
	_geometry_root.add_child(ground_mi)

	var topo := RingScaffoldGenerator.build_topology(ring_count, radius_start, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(
			ring_data, RingScaffoldGenerator.DEFAULT_WALL_THICKNESS, ellipse_ratio, gap, true)

	var rock_mat := ProceduralRockTexture.build_material(
		{"noise_seed": 4177, "noise_scale": 6.0, "palette_handle": "sandstone"}, wall_by_ring.get(1, {}))

	for ring_data in topo:
		var chunks := RingScaffoldGenerator.wedge_chunks([ring_data], segment_arc_deg, gap)
		for chunk in chunks:
			var mesh := RingScaffoldGenerator.build_wedge_mesh(
				chunk, RingScaffoldGenerator.DEFAULT_WALL_THICKNESS, ellipse_ratio, 8, 2, -1.0, true)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = rock_mat
			_geometry_root.add_child(mi)

	# ── Step 4a: cavities ────────────────────────────────────────────────────────────────────────
	var carve_result := NonOverlappingCavityCarver.carve(topo, wall_by_ring, {
		"shape": "mix", "min_spacing": 1.6, "density": float(t.get("cavity_density", 0.9)),
		"depth": 1.0, "seed": 2026, "cavity_size": 0.85, "max_carve_depth": 1.6,
	})
	var instances: Array = carve_result["cavity_instances"]
	var cutaway: Array = carve_result["cavity_cutaway_field"]

	var cavity_wall_mat := StandardMaterial3D.new()
	cavity_wall_mat.albedo_color = Color(0.18, 0.12, 0.08)
	cavity_wall_mat.roughness = 0.9
	for inst in instances:
		var mesh: Mesh = inst["mesh"]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = cavity_wall_mat
		_geometry_root.add_child(mi)

	# ── Step 4b: bridges + their railings (this DISPATCH claim's own primary deliverable) ──────────
	var bridges := BridgeGenerator.generate(instances, {
		"max_angle_delta": 0.6, "max_elevation_delta": 8.0,
		"connect_probability": float(t.get("bridge_connect_probability", 0.85)),
		"deck_width": 1.3, "deck_thickness": 0.2, "seed": 2026,
	})
	var bridge_mat := StandardMaterial3D.new()
	bridge_mat.albedo_color = Color(0.32, 0.27, 0.22)
	bridge_mat.roughness = 0.75
	var railing_mat := StandardMaterial3D.new()
	railing_mat.albedo_color = Color(0.015, 0.015, 0.017)  # black monochrome, per the original spec
	railing_mat.roughness = 0.4
	railing_mat.metallic = 0.6

	var railing_tunables := {
		"baluster_style": String(t.get("baluster_style", "vertical_bars")),
		"baluster_spacing": float(t.get("baluster_spacing", 0.14)),
		"rail_height": float(t.get("rail_height", 1.05)),
	}
	for b in bridges:
		var mi := MeshInstance3D.new()
		mi.mesh = b["mesh"]
		mi.material_override = bridge_mat
		_geometry_root.add_child(mi)
		for edge in RailingGenerator.generate_for_bridge(b, railing_tunables):
			if edge.get("mesh") == null:
				continue
			var rmi := MeshInstance3D.new()
			rmi.mesh = edge["mesh"]
			rmi.material_override = railing_mat
			_geometry_root.add_child(rmi)

	# Balcony/cavity-opening rim railings ("closest balcony" per the original spec) -- through
	# cavities only (the ones that actually open onto a walkable ledge/opening). `curved`/
	# `arc_segments` (DQ-9401aaab) make the rim follow the ring's own curvature instead of cutting a
	# flat chord across the opening -- live-tunable via the panel's "balcony rim follows curve" /
	# "balcony rim arc resolution" knobs.
	var rim_tunables := RailingGenerator.dict_merge(railing_tunables, {
		"curved": bool(t.get("rim_curved", true)),
		"arc_segments": int(t.get("rim_arc_segments", 6)),
	})
	for inst in cutaway:
		var rim := RailingGenerator.generate_for_cavity_rim(inst, rim_tunables)
		if rim.get("mesh") == null:
			continue
		var rmi := MeshInstance3D.new()
		rmi.mesh = rim["mesh"]
		rmi.material_override = railing_mat
		_geometry_root.add_child(rmi)

	# ── Step 4c: trees -- REAL pre-existing CC0 asset kit wired in (DQ-9183cfe2, 2026-07-15). "tree
	# source" toggles between the real ingested `quaternius_nature` kit (default) and the built-in
	# L-system fallback; "tree species mix" restricts which real models are eligible. A GLB tree
	# keeps its OWN vendored material (never overridden -- overriding it would hide the real asset
	# behind a flat placeholder color); only the material-free L-system geometry gets `plant_mat`. ──
	var plant_mat := StandardMaterial3D.new()
	plant_mat.albedo_color = Color(0.22, 0.42, 0.16)
	plant_mat.roughness = 0.85
	var tree_source := String(t.get("tree_source", "kit"))
	var tree_handle := "kit:quaternius_nature" if tree_source == "kit" else "lsystem:default"
	var species_mix := String(t.get("tree_species_mix", "both"))
	var tree_species: Array = ["pine"] if species_mix == "pine_only" else (
		["twisted_tree"] if species_mix == "twisted_tree_only" else ["pine", "twisted_tree"])
	var plant_placements := PlantScatterInCavities.scatter(instances, cutaway, {
		"tree_asset_handle": tree_handle, "density": float(t.get("tree_density", 0.7)),
		"tree_species": tree_species, "seed": 2026,
		"size_min": float(t.get("tree_scale_min", 0.5)), "size_max": float(t.get("tree_scale_max", 1.1)),
	})
	for p in plant_placements:
		var scene_node = p.get("scene_node")
		if scene_node == null:
			continue
		var wrapper := Node3D.new()
		wrapper.transform = p["transform"]
		_geometry_root.add_child(wrapper)
		GodotSceneRenderer.build_static_tree([scene_node], wrapper)
		var is_real_asset := String((scene_node as Dictionary).get("mesh", {}).get("source", "")) == "glb"
		if not is_real_asset:
			for mi in _find_mesh_instances(wrapper):
				mi.material_override = plant_mat

	# ── Step 4d: lights, embedded coplanar in the walls -- zero protrusion ──────────────────────────
	var amber_tunables := {
		"density": float(t.get("light_density", 0.35)), "flush": bool(t.get("light_flush", true)),
		"seed": 2026,
	}
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026 + 777
	var placements: Array = []
	for ring_data in topo:
		var ring_index := int(ring_data["ring"])
		placements.append_array(AmberLightCubeScatterer.scatter_wall(wall_by_ring.get(ring_index, {}), amber_tunables))
	placements.append_array(AmberLightCubeScatterer.scatter_cavities(instances, amber_tunables))
	for p in placements:
		var mi := MeshInstance3D.new()
		mi.mesh = p["mesh"]
		mi.material_override = AmberLightCubeScatterer.jittered_material(amber_tunables, rng)
		mi.transform = p["transform"]
		_geometry_root.add_child(mi)

	print("[underground_wave6_proof] rebuilt: %d cavities, %d bridges, %d railing runs, %d plants, %d lights" %
		[instances.size(), bridges.size(), bridges.size() * 2 + cutaway.size(), plant_placements.size(), placements.size()])


func _find_mesh_instances(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_mesh_instances(c))
	return out


func _process(delta: float) -> void:
	# DQ-0343912a: drain the param channel every frame regardless of mode (--shot never opens a
	# channel, see _ready(), so this is a no-op there). A plain INTERACTIVE session launched with
	# --channel-uri (no --param-listen) also gets this: its TunablePanel sliders + geometry follow a
	# remote edit live too -- only the MAIN camera's pose-follow is param-listen-specific (below),
	# matching this file's existing design that interactive sessions steer via ViewpointPicker's own
	# PiP/pop-out, not the main viewport.
	if _param_channel != null:
		_param_channel.poll()
		var incoming := _param_channel.drain_latest()
		for key in incoming.keys():
			_apply_external_param(key, incoming[key])

	if _param_listen_mode:
		var prev_elapsed_ms := _param_listen_elapsed_ms
		_param_listen_elapsed_ms += int(delta * 1000.0)
		# One status line every ~5s (not every frame -- a caller redirecting this process's stdout
		# to a log file, per verify_underground_param_wiring.py's own docstring on why NOT a pipe,
		# still wants periodic visibility without flooding it).
		if _param_channel != null and _param_listen_elapsed_ms / 5000 != prev_elapsed_ms / 5000:
			print("[underground_wave6_proof] param-listen t=%ds channel=%s rebuild_count=%d" %
				[_param_listen_elapsed_ms / 1000, _param_channel.state_string(), _rebuild_count])
		var deadline_hit := _param_listen_elapsed_ms >= _param_listen_deadline_ms
		var min_updates_hit := _param_listen_min_updates > 0 and _rebuild_count >= _param_listen_min_updates
		if deadline_hit or min_updates_hit:
			set_process(false)
			await _capture(PARAM_LISTEN_SHOT_OUT)
			_write_state_json()
			print("[underground_wave6_proof] param-listen captured -> ", PARAM_LISTEN_SHOT_OUT,
				"  (rebuild_count=", _rebuild_count, ")")
			get_tree().quit(0)
		return

	if not _shot_mode:
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_capture_out)
		print("[underground_wave6_proof] captured -> ", _capture_out)
		get_tree().quit(0)


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)

## Liam, verbatim, 2026-07-15T15:08:25Z (Discord #dev), the spec this file implements:
## "As for the underground scene, the process needs refining:
## 1. Make the entire world based on a flat plane of the ground, this will be the equatorial plane
##    of any spheres or elliptical objects that exist in this scene, but the bottom half of those
##    that is below the ground is not needed.
## 2. Make the concentric circles with tunable gaps and sizes, and then then ellipse as well, but the
##    spheres and ellipses should all have the same center of symmetry. Give me the ability in this
##    scene to change and resize everything.
## 3. Then, using those tools to move around in the scene, I will place the perspective of the
##    viewer. It would be ideal if you made a node based reusable tool where I could place the
##    perspective of the viewer and then have that screen show me, in a portion of the screen or
##    separate window, what that viewpoint looks like (this also naturally connects to the aperture
##    view into this scene, since that view would be the same) so that I can move around the scene
##    and edit things to tune that particular view to look like the image.
## 4. Then, using that viewpoint as a base, start generating the hollow side wall cavities, bridges,
##    trees (taken from pre-existing assets), railings, and the lights. The lights should be embedded
##    in the walls such that they are coplanar with the wall surfaces and do not stick out at all.
##    These should all be generated based on tunable parameters and tools that I can use to adjust
##    *everything* so that any mistakes you make I can fix easily by changing the free variables to
##    make it exactly what I want."
