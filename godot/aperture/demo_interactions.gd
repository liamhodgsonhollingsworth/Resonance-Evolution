extends Node
## DEMO CONTROLLER — the runnable, VISIBLE interaction + VISI-SONOR LIGHT-SHOW demo.
##
## Slice-5 origin: it COMPOSES the landed pieces (it builds NOTHING new about the room or the
## primitives) into the one thing Liam opens and tries. It:
##   1. builds the REAL Aperture3D room (the same scene the shortcut opens) as a child, so the demo runs
##      inside the actual walkable room — additive, no mutation of aperture_3d.gd;
##   2. boots the ui.* + device.* host op families (register_ui_ops / register_device_ops), so a
##      WorldAction node honours dialogue.show / ui.menu.open / device.set_led;
##   3. mounts the minimal in-world UI renderer (ui_action_renderer.gd) on the room — additive overlay;
##   4. loads the THREE demo arrangements into three room-owned GraphRuntimes (A button->dialogue,
##      B area->menu, C live band->led);
##   5. each tick, INJECTS the per-frame input frame each arrangement reads (the F2 portability seam):
##      the interact keypress, the live player position (for the area proximity), and — NOW — the LIVE
##      analyzer band (not a sin() oscillator); then EVALUATES each runtime and routes the WorldAction
##      receipts to the UI renderer / the LED chip.
##
## VISI-SONOR ITEM-10 DEMO LAYER (Wave 4 — the reportable near-term anchor, additive on top of Slice-5):
##   • AUDIO: an mp3 (a bundled royalty-free / synthetic clip) plays on a dedicated "VisiSonor" audio bus
##     that carries a mounted AudioEffectSpectrumAnalyzer (the 1A gap fix — nothing else mounts it). A
##     PrimAudioSource(mp3) feeds the bus; a PrimSpectrum reads the analyzer -> N log bands; a
##     PrimSpectrumBands folds those into signal.band.low/mid/high. If no mp3 loads, a PrimDemoAudioLoop
##     (synthetic spectrum) drives the SAME frame keys so the demo is audio-reactive regardless (C-ideal).
##   • ROOM: demo_visisonor_room.json is loaded + rendered via GodotSceneRenderer (shell + 3 lamps + a
##     12-pixel LED strip + a TV/screen quad — NO projector, color/brightness/timing only).
##   • WIRING: each frame the live bands are injected via set_input_frame, then PrimFreqToColor (bass=warm/
##     treble=cool) + PrimSizeSortBind (big lamps->bass, small LEDs->treble) + PrimParamBind drive
##     device.set_led for every fixture; the receipt colours re-drive the live Light3D nodes so the room
##     lights pulse with the music. The screen runs the classic spectrum-bars viz off the SAME band frame.
##
## CONTROLS (kept obvious; also printed to stdout):
##   • WASD + mouse            — walk / look (the room's own first-person controller).
##   • E                       — INTERACT: shows the dialogue box (demo A). Dismiss with E or the button.
##   • walk to the RED marker  — enter the area (~centre-front): the menu opens (demo B); leave to close.
##   • the LED swatch (top-L)  — driven by the LIVE analyzer high-band (demo C); watch it fade warm<->cool.
##   • hold B                  — force the band HIGH (warm) so you can see the LED flip on demand.
##   • P                       — play / pause the mp3.
##   • ESC                     — release the mouse (room default).
##
## Open live (GUI, windowed):
##   C:\Users\Liam\godot\Godot_v4.6.3-stable_win64.exe --path godot res://demo_interactions.tscn
## (the GUI exe, NOT the console one — the console exe is for headless stdout tests.)

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const UiActionRenderer := preload("res://aperture/ui_action_renderer.gd")
const UiActions := preload("res://runtime/ui_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")
const WorldActions := preload("res://runtime/world_actions.gd")
const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")
const PrimAudioSourceRef := preload("res://primitives/prim_audio_source.gd")
const PrimSpectrumRef := preload("res://primitives/prim_spectrum.gd")
const PrimSpectrumBandsRef := preload("res://primitives/prim_spectrum_bands.gd")
const PrimDemoAudioLoopRef := preload("res://primitives/prim_demo_audio_loop.gd")
const PrimFreqToColorRef := preload("res://primitives/prim_freq_to_color.gd")
const PrimSizeSortBindRef := preload("res://primitives/prim_size_sort_bind.gd")
const PrimParamBindRef := preload("res://primitives/prim_param_bind.gd")
const PrimScreenRef := preload("res://primitives/prim_screen.gd")
const PrimVideoSourceRef := preload("res://primitives/prim_video_source.gd")

# The bundled demo clip + the audio bus that carries the analyzer. If the clip is absent the demo falls
# back to the synthetic PrimDemoAudioLoop, so the room is always audio-reactive on open (C-ideal).
const DEMO_MP3 := "res://assets/audio/demo_tone_sweep_beat.mp3"
const VS_BUS := "VisiSonor"
const VS_ROOM := "res://arrangements/demo_visisonor_room.json"

# The area centre for demo B (matches demo_area_menu.json's `area` Const). A visible red marker is placed
# here so the player can SEE where to walk. y is the player's eye height so the proximity distance is planar.
const AREA_CENTRE := Vector3(4.0, 1.7, -4.0)

var room: Node3D = null
var _rt_dialogue: GraphRuntime = null
var _rt_menu: GraphRuntime = null
var _rt_led: GraphRuntime = null

var _interact_pulse := false   # set for exactly one evaluate when E is pressed (edge-triggered)
var _force_high := false       # hold B => band forced high (warm)
var _t := 0.0
var _headless := false

# The on-screen LED indicator (demo C): a small ColorRect tinted from the device.set_led receipt so the
# mapped colour is VISIBLE without real hardware. Mounted on its own CanvasLayer (additive to the room).
var _led_swatch: ColorRect = null
var _led_label: Label = null

# --- VISI-SONOR layer state (Wave 4, additive) -----------------------------------------------------
var _audio_src = null           # mp3 source on the VisiSonor bus (null in fallback mode)
var _spectrum = null               # reads the analyzer on the bus -> raw log bands
var _spectrum_bands = null    # raw bands -> named + low/mid/high
var _demo_loop = null         # synthetic fallback source (when no mp3 or no live audio)
var _freq_to_color = null       # bass=warm / treble=cool ramp per fixture
var _size_sort = null          # big lamps->bass, small strip pixels->treble
var _param_bind = null            # fixture band value -> shaped brightness (item 8)
var _analyzer_ready := false                     # the AudioEffectSpectrumAnalyzer is mounted on the bus
var _audio_live := false                         # a real mp3 stream is loaded + playing (vs fallback)

var _vs_room_rt: GraphRuntime = null             # the demo_visisonor_room.json runtime
var _vs_renderer = null                          # GodotSceneRenderer instance building the room in-tree
var _screen_quad: MeshInstance3D = null          # the TV/screen quad the controller builds + textures
var _screen_mat: StandardMaterial3D = null       # its material (albedo_texture swapped each frame)
var _screen_phase := 0                           # classic-viz animation phase
var _last_screen_stats := { "mean": 0.0, "variance": 0.0 }

# --- LIGHT-SHOW LOOK state (Wave 4 polish, demo-side) ----------------------------------------------
var _demo_world_env: WorldEnvironment = null     # the ONE dark light-show environment (dark bg + glow)
var _lamp_glow_meshes: Dictionary = {}           # light_key -> emissive glow MeshInstance3D at each lamp

# Fixture table: one entry per drivable light/pixel. { addr, size, light_key } — `size` feeds SizeSortBind
# (big=bass), `light_key` re-drives the matching live Light3D. Built from the room's evaluated fixtures.
var _fixtures: Array = []
# The last device.set_led receipt per addr (headless test reads this to assert RGB tracks the band).
var _led_receipts: Dictionary = {}
# The bindings SizeSortBind produced (addr -> band_key). Recomputed once at setup (sizes are static).
var _addr_band: Dictionary = {}


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# 1. the REAL room, as a child (the demo runs inside the actual walkable Aperture3D).
	room = Aperture3D.new()
	room.name = "Aperture3DRoom"
	add_child(room)

	# 2. boot the ui.* + device.* host op families so a WorldAction honours dialogue.show / ui.menu.open /
	#    device.set_led. The builtin-shadow guard in register_host keeps this safe (no ui.* masks a builtin).
	UiActions.register_ui_ops(WorldActions)
	DeviceActions.register_device_ops(WorldActions)

	# 3. mount the minimal UI renderer overlay on the room (force=true is only for headless; live uses false).
	UiActionRenderer.mount(room, _headless)
	_build_led_indicator()

	# 4. load the three demo arrangements into three room-owned runtimes.
	_rt_dialogue = _load_runtime("res://arrangements/demo_button_dialogue.json")
	_rt_menu = _load_runtime("res://arrangements/demo_area_menu.json")
	_rt_led = _load_runtime("res://arrangements/demo_band_led.json")

	# 4b. VISI-SONOR: mount the analyzer bus, build the audio chain, load + render the room, wire fixtures.
	setup_visisonor()

	# 5. a visible red marker at the area centre so the player can see where to walk (demo B). Additive.
	if not _headless:
		_place_area_marker()
		_print_controls()


func _process(delta: float) -> void:
	if room == null or not is_instance_valid(room) or not _runtimes_ready():
		return
	_t += delta
	drive_once(_player_pos(), delta)
	_interact_pulse = false   # the interact pulse lasts exactly one evaluate (edge-triggered)


## All three runtimes are loaded (a guard so a partially-constructed demo — e.g. a test awaiting frames
## during setup — never drives a Nil runtime). Fail-safe: drive_once is a no-op until this is true.
func _runtimes_ready() -> bool:
	return _rt_dialogue != null and _rt_menu != null and _rt_led != null


## THE ONE BACKEND STEP (text-equivalence anchor, gate T): inject the per-frame frame each arrangement
## reads, evaluate the three runtimes, and route their WorldAction receipts to the UI renderer + LED. The
## headless #049 test calls THIS EXACT fn (driving the same runtimes + renderer) — there is no GUI-only
## path. Returns the three receipts { dialogue, menu, led } so a test can assert on them directly.
func drive_once(player_pos: Vector3, dt: float) -> Dictionary:
	if not _runtimes_ready():
		return {}
	# --- demo A: inject the interact pulse; evaluate; render the dialogue receipt --------------------
	_rt_dialogue.set_input_frame({ "action.interact": (1.0 if _interact_pulse else 0.0) })
	var out_a := _rt_dialogue.evaluate()
	var say: Dictionary = out_a.get("say", {}).get("result", {})
	if str(say.get("op", "")) == "dialogue.show" and str(say.get("text", "")) != "":
		UiActionRenderer.render_receipt(room, say)

	# --- demo B: inject the live player position; evaluate; render the menu receipt ------------------
	_rt_menu.set_input_frame({ "player.pos": [player_pos.x, player_pos.y, player_pos.z] })
	var out_b := _rt_menu.evaluate()
	var open_r: Dictionary = out_b.get("open", {}).get("result", {})
	# open with items => inside the area; empty items => outside => close the menu.
	if str(open_r.get("op", "")) == "ui.menu.open" and (open_r.get("items", []) as Array).size() > 0:
		UiActionRenderer.render_receipt(room, open_r)
	elif UiActionRenderer.menu_visible(room):
		UiActionRenderer.render_receipt(room, { "op": "ui.menu.close" })

	# --- VISI-SONOR: the LIVE analyzer band drives the whole light show (replaces the sin() oscillator).
	# compute_bands() reads the real mp3->analyzer->bands chain (or the synthetic fallback); its `high`
	# band feeds demo C's set_input_frame (the SAME key the slice5 oscillator used), AND every room
	# fixture + the screen. hold-B still forces the band high on demand.
	var bands := compute_bands(dt)
	var high := 1.0 if _force_high else float(bands.get("signal.band.high", 0.0))

	# --- demo C: inject the LIVE band; evaluate; tint the LED swatch ---------------------------------
	_rt_led.set_input_frame({ "signal.band.high": high })
	var out_c := _rt_led.evaluate()
	var led: Dictionary = out_c.get("led", {}).get("result", {})
	_apply_led(led)

	# --- the room light show + screen: drive every fixture + re-texture the screen from the same bands.
	drive_visisonor(bands)

	return { "dialogue": say, "menu": open_r, "led": led }


## Fire the interact pulse for exactly the next evaluate (demo A). The GUI calls this on the E key; a test
## calls it directly. Edge-triggered so one press = one dialogue.show, not a held stream.
func pulse_interact() -> void:
	_interact_pulse = true


func _unhandled_input(event: InputEvent) -> void:
	if _headless:
		return
	if event is InputEventKey and not event.echo:
		match event.keycode:
			KEY_E:
				if event.pressed:
					pulse_interact()
			KEY_B:
				_force_high = event.pressed   # hold B => band high
			KEY_P:
				if event.pressed:
					_toggle_play()


# =====================================================================================================
# VISI-SONOR ITEM-10 DEMO LAYER (Wave 4) — additive; the Slice-5 demo above is untouched in behaviour.
# =====================================================================================================

## Build the whole visi-sonor layer: mount the analyzer bus (the 1A gap fix), build the audio chain,
## load + render the room, build the screen quad, and compute the static size->band fixture bindings.
## Every step is C-ideal: a missing mp3 / GLB / analyzer degrades to a defined fallback, never a crash.
func setup_visisonor() -> void:
	_mount_analyzer_bus()
	_build_audio_chain()
	_build_room_and_screen()
	_build_fixture_bindings()


## THE 1A GAP FIX: create the VisiSonor audio bus and MOUNT an AudioEffectSpectrumAnalyzer onto it, so the
## LIVE mp3 path actually produces non-zero analyzer magnitudes. prim_spectrum only READS the analyzer on
## the bus — nothing else mounts it — so without this the live path would read all-zero bands. Idempotent:
## the bus + effect are added once; re-running finds them. Additive: never removes/reorders host buses.
func _mount_analyzer_bus() -> void:
	var idx := AudioServer.get_bus_index(VS_BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, VS_BUS)
		AudioServer.set_bus_send(idx, "Master")
	# Mount the analyzer at effect index 0 if not already present (prim_spectrum reads effect_index 0).
	var has_analyzer := false
	for e in range(AudioServer.get_bus_effect_count(idx)):
		if AudioServer.get_bus_effect(idx, e) is AudioEffectSpectrumAnalyzer:
			has_analyzer = true
			break
	if not has_analyzer:
		var an := AudioEffectSpectrumAnalyzer.new()
		an.buffer_length = 0.1              # ~100ms FFT window (enough resolution, cheap)
		an.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_2048
		AudioServer.add_bus_effect(idx, an, 0)
	_analyzer_ready = true


## Build the mp3 analysis chain: PrimAudioSource(mp3) on the VisiSonor bus -> PrimSpectrum (reads the
## mounted analyzer) -> PrimSpectrumBands. If the mp3 is absent/unreadable, keep the chain but mark it
## non-live and fall back to the synthetic PrimDemoAudioLoop so the demo is audio-reactive regardless.
func _build_audio_chain() -> void:
	# The synthetic fallback source — always present; used when no live audio is available.
	_demo_loop = PrimDemoAudioLoopRef.new()
	add_child(_demo_loop)
	_demo_loop.params = { "bpm": 120.0, "sweep_secs": 8.0, "loop_secs": 12.0 }

	# The named-bands folder + freq->color + size-sort are shared by both the live and fallback paths.
	_spectrum_bands = PrimSpectrumBandsRef.new()
	add_child(_spectrum_bands)
	_spectrum_bands.params = { "band_edges_hz": [20.0, 60.0, 250.0, 500.0, 2000.0, 6000.0, 20000.0], "min_hz": 20.0, "max_hz": 20000.0 }
	_freq_to_color = PrimFreqToColorRef.new()
	add_child(_freq_to_color)
	_freq_to_color.params = { "mode": "warm_cool_ramp", "palette": "default", "value_from": "amplitude" }
	_size_sort = PrimSizeSortBindRef.new()
	add_child(_size_sort)
	# ParamBind shapes each fixture's raw band value into a brightness multiplier (normalize -> curve ->
	# envelope -> remap). A light's brightness IS a bound feature (item 8) — the SAME node a screen bar
	# height would use. out 0.15..1.0 so a lit fixture never goes fully black on a soft frame.
	_param_bind = PrimParamBindRef.new()
	add_child(_param_bind)
	_param_bind.params = { "in_min": 0.0, "in_max": 1.0, "curve_shape": "exp", "curve_k": 1.5, "attack": 0.6, "release": 0.25, "out_min": 0.15, "out_max": 1.0 }

	# The LIVE mp3 source + analyzer reader. In headless the audio driver is dummy (no real magnitudes),
	# so the fallback carries the demo; live (GUI) the analyzer produces real bands.
	_audio_src = PrimAudioSourceRef.new()
	add_child(_audio_src)
	_audio_src.params = { "source_kind": "mp3", "path": DEMO_MP3, "bus": VS_BUS, "autoplay": true, "loop": true }
	var out: Dictionary = _audio_src.evaluate({})
	_audio_live = bool(out.get("ok", false)) and out.get("pcm_stream") != null and _analyzer_ready

	_spectrum = PrimSpectrumRef.new()
	add_child(_spectrum)
	_spectrum.params = { "bus": VS_BUS, "effect_index": 0, "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.5, "gain": 4.0 }


## Load the room arrangement, render it into the room via GodotSceneRenderer (shell + lamps + strip
## lights), and build the TV/screen quad the controller textures each frame. Additive to the Aperture3D
## room; a missing GLB falls back to placeholder meshes inside AssetImport, so this always renders.
func _build_room_and_screen() -> void:
	_vs_room_rt = GraphRuntime.new()
	add_child(_vs_room_rt)
	_vs_room_rt.load_json(VS_ROOM)
	var eval := _vs_room_rt.evaluate()
	var arr: Dictionary = _vs_room_rt.arrangement

	# Render the scene_node roots (shell + lamps grouped) + the lights into the room subtree.
	_vs_renderer = GodotSceneRenderer.new()
	room.add_child(_vs_renderer)
	_vs_renderer.render(eval, arr)
	_vs_renderer.apply_lights(eval, arr, _vs_renderer)
	_vs_renderer.apply_environment(eval, arr, _vs_renderer)

	# Build the screen quad from the Screen descriptor (build_node does not handle a `screen`/quad, so the
	# controller mounts it — a plain textured quad, renderer-neutral descriptor -> a concrete quad here).
	var screen_desc: Dictionary = eval.get("screen", {}).get("screen", {})
	_build_screen_quad(screen_desc)

	# DEMO LIGHT-SHOW LOOK (Wave 4 polish, demo-side only — no primitive edits). A light show needs a DARK
	# room so the colored reactive lights POP; the default procedural sky + near-white placeholder walls read
	# as blown-out. This override runs AFTER the renderers have mounted their environments: it (1) mounts ONE
	# dark WorldEnvironment (dark bg, tiny ambient, ACES tonemap, glow/bloom so bright reactive lights bloom),
	# retiring any brighter env the room/renderer mounted; (2) darkens the placeholder shell + floor so light
	# pools show; (3) dims the room's daytime sun; (4) drops a small emissive glow mesh at each lamp so the
	# fixture visibly emits. All of this is demo-setup tuning — the shared primitives are untouched.
	_apply_light_show_look()


## Build the flat TV/screen quad in-room from the Screen descriptor: a QuadMesh with an unshaded
## StandardMaterial3D whose albedo_texture is swapped each frame (the classic-viz PNG). Non-blank on open.
func _build_screen_quad(desc: Dictionary) -> void:
	var size := _v2(desc.get("size", [2.4, 1.35]), Vector2(2.4, 1.35))
	var pos := _v3d(desc.get("transform", {}).get("translation", [0.0, 1.7, -3.9]), Vector3(0.0, 1.7, -3.9))
	_screen_quad = MeshInstance3D.new()
	_screen_quad.name = "VisiSonorScreen"
	var qm := QuadMesh.new()
	qm.size = size
	_screen_quad.mesh = qm
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_screen_mat.albedo_color = Color(1, 1, 1)
	# UNSHADED already makes the albedo render at full brightness regardless of room ambient, but flag the
	# quad emissive too (so bloom catches the bright bars) and disable fog so the bars stay crisp in a dark
	# room. The classic-viz PNG is swapped into albedo_texture each frame; unshaded => it reads at full
	# contrast even in a near-black room (the fix for "bars invisible because ambient washed the quad out").
	_screen_mat.disable_receive_shadows = true
	# UNSHADED already renders albedo_texture at full brightness. A light emission ADD lets the bright bars
	# tip past 1.0 so bloom catches them, WITHOUT lifting the dark background of the viz frame into gray
	# (the background pixels are ~0.06, so +0.06*energy stays near-black; the bars ~1.0 bloom).
	_screen_mat.emission_enabled = true
	_screen_mat.emission = Color(1, 1, 1)
	_screen_mat.emission_energy_multiplier = 0.8
	_screen_mat.emission_operator = BaseMaterial3D.EMISSION_OP_ADD
	_screen_quad.material_override = _screen_mat
	_screen_quad.position = pos
	room.add_child(_screen_quad)
	# A thin dark bezel behind the screen so the bright bars read against a frame, not the wall.
	var bezel := MeshInstance3D.new()
	bezel.name = "VisiSonorScreenBezel"
	var bqm := QuadMesh.new()
	bqm.size = size * 1.08
	bezel.mesh = bqm
	var bmat := StandardMaterial3D.new()
	bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bmat.albedo_color = Color(0.02, 0.02, 0.03)
	bezel.material_override = bmat
	bezel.position = pos + Vector3(0, 0, -0.02)
	room.add_child(bezel)


## DEMO LIGHT-SHOW LOOK — mount ONE dark WorldEnvironment (dark bg, tiny ambient, ACES tonemap, glow),
## darken the placeholder shell/floor so light pools show, dim the daytime sun, and add a glow mesh at each
## lamp. Demo-side only: it tunes the LIVE Environment/materials the renderers produced; it does not edit
## prim_environment / prim_light / the scene renderer. Idempotent-safe (re-running rebuilds the demo env).
func _apply_light_show_look() -> void:
	# 1. Retire every WorldEnvironment already in the scene (the Aperture3D room mounts its own bright sky,
	#    and _vs_renderer.apply_environment mounts a second) and any daytime sun, so only OUR dark env + the
	#    reactive lights light the room. We dim (not delete) the suns so shadows/keys still exist faintly.
	for we in _find_nodes_of_type(get_tree().get_root(), "WorldEnvironment"):
		if we != _demo_world_env:
			we.queue_free()
	for dl in _find_nodes_of_type(get_tree().get_root(), "DirectionalLight3D"):
		(dl as DirectionalLight3D).light_energy = 0.08   # a whisper of key light, not a daytime sun

	# 2. Build the dark light-show environment.
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.015, 0.015, 0.025)      # near-black room
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.04, 0.045, 0.06)     # a faint cool fill so shadows aren't pure black
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_ACES        # filmic rolloff so bright pools don't clip white
	env.tonemap_exposure = 0.9
	env.tonemap_white = 4.0
	# GLOW / BLOOM — the thing that makes a light show read as a light show: bright reactive pools + the
	# screen bars bloom. Threshold below 1.0 so the emissive lamps/screen catch it.
	env.glow_enabled = true
	env.glow_intensity = 0.9
	env.glow_strength = 1.1
	env.glow_bloom = 0.35
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 0.85
	# Enable the mid glow levels for a broad, soft bloom.
	env.set("glow_levels/2", true)
	env.set("glow_levels/3", true)
	env.set("glow_levels/4", true)
	# A gentle dark fog for depth so the far wall recedes into the dark (adds atmosphere, keeps focus on light).
	env.fog_enabled = true
	env.fog_light_color = Color(0.02, 0.02, 0.04)
	env.fog_density = 0.015
	_demo_world_env = WorldEnvironment.new()
	_demo_world_env.name = "VisiSonorLightShowEnv"
	_demo_world_env.environment = env
	room.add_child(_demo_world_env)

	# 3. Darken the placeholder shell + floor so colored light pools are clearly visible against them.
	_darken_room_surfaces()

	# 4. A small emissive glow mesh at each lamp position so you can SEE the fixture emitting (bloom-friendly).
	_build_lamp_glow_meshes()


## Walk the rendered shell subtree and give every placeholder MeshInstance3D a mid-dark matte material so
## colored light reads against it (the placeholder box shell + cylinders default to a bright white material).
## Only the demo's own rendered fixtures/shell are touched (under _vs_renderer); the Aperture3D room's own
## geometry keeps its material. Skips the screen quad + its bezel + lamp glow meshes (those are emissive).
func _darken_room_surfaces() -> void:
	if _vs_renderer == null or not is_instance_valid(_vs_renderer):
		return
	var wall := StandardMaterial3D.new()
	wall.albedo_color = Color(0.10, 0.10, 0.13)   # dark blue-grey walls
	wall.roughness = 0.95
	wall.metallic = 0.0
	for mi in _find_nodes_of_type(_vs_renderer, "MeshInstance3D"):
		var n := str((mi as Node).name)
		if n.begins_with("VisiSonor") or n.find("Glow") >= 0:
			continue
		(mi as MeshInstance3D).material_override = wall


## Drop a small unshaded emissive sphere at each lamp's position so the fixture visibly emits (and blooms).
## The glow colour is re-driven each frame by drive_visisonor via _recolor_fixture_light's sibling call, so
## the emitter pulses with the light. Additive demo geometry — not part of any arrangement/primitive.
func _build_lamp_glow_meshes() -> void:
	var lamp_positions := {
		"r:lamp_a_light/light": Vector3(-2.5, 2.2, -2.5),
		"r:lamp_b_light/light": Vector3(2.5, 1.6, -2.5),
		"r:lamp_c_light/light": Vector3(0.0, 3.6, 0.0),
	}
	for key in lamp_positions.keys():
		var mi := MeshInstance3D.new()
		mi.name = "VisiSonorLampGlow_" + str(key).replace("/", "_").replace(":", "_")
		var sph := SphereMesh.new()
		sph.radius = 0.18
		sph.height = 0.36
		mi.mesh = sph
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.emission_enabled = true
		mat.emission = Color(1, 1, 1)
		mat.emission_energy_multiplier = 2.0
		mat.albedo_color = Color(1, 1, 1)
		mi.material_override = mat
		mi.position = lamp_positions[key]
		room.add_child(mi)
		_lamp_glow_meshes[str(key)] = mi


## Depth-first search for every node of a class (by class name string) under `root`. Used to find the
## live WorldEnvironment / DirectionalLight3D / MeshInstance3D nodes the renderers built, so the demo can
## tune them WITHOUT the renderer exposing them — a demo-side, additive reach-in (no primitive edit).
func _find_nodes_of_type(root: Node, cls: String) -> Array:
	var out: Array = []
	if root == null or not is_instance_valid(root):
		return out
	if root.is_class(cls):
		out.append(root)
	for c in root.get_children():
		out.append_array(_find_nodes_of_type(c, cls))
	return out


## Compute the static size->band fixture bindings once (SizeSortBind), and record the light_key each
## fixture's live Light3D was rendered under so drive_visisonor can re-color the matching instance. Big
## fixtures (the lamps) -> bass; small pixels (the strip) -> treble.
func _build_fixture_bindings() -> void:
	# The three lamps (big) + the strip pixels (small). Sizes are relative: lamps large, strip pixels tiny.
	# addr matches demo_visisonor_room.json's Light addr + the strip's base_addr..base_addr+count.
	_fixtures = []
	_fixtures.append({ "addr": 0, "size": 1.0, "light_key": "r:lamp_a_light/light" })
	_fixtures.append({ "addr": 1, "size": 0.8, "light_key": "r:lamp_b_light/light" })
	_fixtures.append({ "addr": 2, "size": 0.6, "light_key": "r:lamp_c_light/light" })
	# The LED strip: 12 small pixels (addr 100..111). One representative binding per pixel (all small).
	for i in range(12):
		_fixtures.append({ "addr": 100 + i, "size": 0.1, "light_key": "" })

	# SizeSortBind maps each fixture (by size rank) to a band key. Big -> low (bass); small -> high (treble).
	var sizes: Array = []
	for f in _fixtures:
		sizes.append(f["size"])
	_size_sort.params = { "sizes": sizes, "ascending": true }
	var bindings: Array = _size_sort.evaluate({}).get("bindings", [])
	_addr_band = {}
	for i in range(bindings.size()):
		if i < _fixtures.size():
			_addr_band[_fixtures[i]["addr"]] = str(bindings[i].get("band_key", "signal.band.mid"))


## Compute the current named bands ({ signal.band.low/mid/high, ... }) from the LIVE mp3->analyzer chain
## when audio is live, else the synthetic PrimDemoAudioLoop. Always returns a defined dict (C-ideal). This
## is the ONE place that replaces the slice5 sin() oscillator with the real feed.
func compute_bands(dt: float) -> Dictionary:
	if _audio_live and _spectrum != null and _spectrum_bands != null:
		# LIVE: pump the source (advances the playhead), read the analyzer bands, fold into named bands.
		_audio_src.evaluate({})
		var raw = _spectrum.evaluate({}).get("bands")
		var named: Dictionary = _spectrum_bands.evaluate({ "bands": raw }).get("named", {})
		# If the live analyzer produced ~silence (e.g. headless dummy driver), fall through to synthetic so
		# the demo is never dead. A tiny sum means no real magnitudes reached the bus.
		var live_sum := float(named.get("low", 0.0)) + float(named.get("mid", 0.0)) + float(named.get("high", 0.0))
		if live_sum > 0.001:
			return _seam_dict(named)
	# FALLBACK: the synthetic loop (headless, or no mp3, or a silent live frame). It emits the SAME keys.
	_t += 0.0   # (time already advanced by _process; _demo_loop reads its own t below)
	var frame: Dictionary = _demo_loop.evaluate({ "t": _t }).get("frame", {})
	return frame


## Map a prim_spectrum_bands `named` dict (keys low/mid/high + sub/bass/lowmid/mid_band/highmid/treble)
## into the signal.band.* seam keys the fixtures + screen + demo-C arrangement read. This is the injector
## step — the EXACT keys set_input_frame speaks — so the live analyzer lights up every existing consumer.
func _seam_dict(named: Dictionary) -> Dictionary:
	return {
		"signal.band.low": float(named.get("low", 0.0)),
		"signal.band.mid": float(named.get("mid", 0.0)),
		"signal.band.high": float(named.get("high", 0.0)),
		"signal.band.sub": float(named.get("sub", 0.0)),
		"signal.band.lowmid": float(named.get("lowmid", 0.0)),
		"signal.band.highmid": float(named.get("highmid", 0.0)),
		"signal.energy": clampf(0.5 * float(named.get("low", 0.0)) + 0.3 * float(named.get("mid", 0.0)) + 0.2 * float(named.get("high", 0.0)), 0.0, 1.0),
	}


## Drive every room fixture from the current bands: each fixture reads ITS bound band (via SizeSortBind),
## runs it through FreqToColor (bass=warm/treble=cool) + ParamBind (brightness), fires device.set_led, and
## the receipt colour re-drives the matching live Light3D so the room lights pulse. Also re-textures the
## screen from the same bands. Records each receipt in _led_receipts for the headless test to assert on.
func drive_visisonor(bands: Dictionary) -> void:
	var low := float(bands.get("signal.band.low", 0.0))
	var high := float(bands.get("signal.band.high", 0.0))
	var wa := WorldActions.new()   # a fresh registry inheriting the host-wide device.* ops (booted in _ready)

	for f in _fixtures:
		var addr: int = int(f["addr"])
		var band_key := str(_addr_band.get(addr, "signal.band.mid"))
		var band_val := float(bands.get(band_key, 0.0))
		# Warm/cool colour from THIS fixture's band balance: a bass-bound fixture sees strong `bass`,
		# a treble-bound fixture sees strong `treble`, so the ramp lands warm/cool per the item-6 spec.
		# amplitude = the fixture's own band value -> a quiet band dims that fixture.
		var col: Dictionary = _freq_to_color.evaluate({
			"bass": low, "treble": high, "amplitude": band_val,
		}).get("value", {})
		# ParamBind shapes brightness from the fixture's own band value (a light's brightness IS a bound
		# feature — item 8): bands -> freq_to_color + size_sort_bind -> param_bind -> device.set_led. out
		# 0.15..1.0 so a lit fixture never goes fully black on a soft frame. Multiply the ramp RGB by it.
		var bright := float(_param_bind.evaluate({ "x": band_val }).get("value", 1.0))
		col["r"] = float(col.get("r", 0.0)) * bright
		col["g"] = float(col.get("g", 0.0)) * bright
		col["b"] = float(col.get("b", 0.0)) * bright
		_freq_to_color_addr_override(col, addr)
		# Fire device.set_led through the real op registry (declarative receipt).
		var receipt: Dictionary = wa.perform("device.set_led", { "value": col })
		_led_receipts[addr] = receipt
		# Re-drive the matching live light: tint it the receipt colour, energy from the band value.
		_recolor_fixture_light(str(f["light_key"]), receipt, band_val)

	# The screen: classic spectrum-bars off the SAME (low,mid,high) band frame.
	_update_screen(bands)


## Give the freq_to_color receipt this fixture's addr (the payload carries addr:0 from the node default).
func _freq_to_color_addr_override(col: Dictionary, addr: int) -> void:
	if typeof(col) == TYPE_DICTIONARY:
		col["addr"] = addr


## Re-color a live Light3D from a device.set_led receipt so the room lights pulse with the music. The
## light_key is the render key GodotSceneRenderer built the light under. Energy scales with the band value
## (a soft floor so a lit lamp never fully dies), colour is the receipt RGB.
func _recolor_fixture_light(light_key: String, receipt: Dictionary, band_val: float) -> void:
	if light_key == "" or _vs_renderer == null:
		return
	var lights: Dictionary = _vs_renderer.get("_lights")
	if lights == null or not lights.has(light_key):
		return
	var light = lights[light_key]
	if not is_instance_valid(light):
		return
	var col := Color(
		clampf(float(receipt.get("r", 0.0)), 0.0, 1.0),
		clampf(float(receipt.get("g", 0.0)), 0.0, 1.0),
		clampf(float(receipt.get("b", 0.0)), 0.0, 1.0))
	light.light_color = col
	# Vivid reactive pools in a dark room: a strong floor so a lit fixture always throws a visible colored
	# pool/cone, scaling up hard with the band so the beat clearly pulses. (The dark env + glow make this read.)
	light.light_energy = 1.6 + 8.0 * clampf(band_val, 0.0, 1.0)
	# Pulse the matching emissive glow mesh so the fixture itself visibly emits + blooms with its band.
	if _lamp_glow_meshes.has(light_key):
		var gm = _lamp_glow_meshes[light_key]
		if is_instance_valid(gm) and gm.material_override != null:
			var m: StandardMaterial3D = gm.material_override
			m.emission = col
			m.emission_energy_multiplier = 1.5 + 4.0 * clampf(band_val, 0.0, 1.0)


## Re-texture the screen quad with a fresh classic-viz frame from the (low,mid,high) band levels. Records
## the frame stats (variance>0 <=> non-blank) so the headless test can assert the screen renders.
func _update_screen(bands: Dictionary) -> void:
	if _screen_mat == null:
		return
	var lo := clampf(float(bands.get("signal.band.low", 0.0)), 0.0, 1.0)
	var mid := clampf(float(bands.get("signal.band.mid", 0.0)), 0.0, 1.0)
	var hi := clampf(float(bands.get("signal.band.high", 0.0)), 0.0, 1.0)
	var img := PrimScreenRef.classic_viz_frame(96, 54, [lo, mid, hi], _screen_phase)
	_screen_phase += 1
	_last_screen_stats = PrimVideoSourceRef.image_stats(img)
	var tex := ImageTexture.create_from_image(img)
	_screen_mat.albedo_texture = tex


## Play/pause the mp3 (the P key). No-op in fallback mode (no live source). Public seam.
func _toggle_play() -> void:
	if _audio_src == null:
		return
	if _audio_src.has_method("play"):
		# Toggle by inspecting the internal player if present; simplest robust toggle: stop if playing else play.
		var pl = _audio_src.get("_player")
		if pl != null and is_instance_valid(pl) and pl.playing:
			_audio_src.stop()
		else:
			_audio_src.play()


# --- headless test seams (no GUI-only path; the test drives THESE) --------------------------------

## Force the live/fallback mode for a deterministic headless test. mode "synthetic" pins the demo loop.
func force_audio_mode(live: bool) -> void:
	_audio_live = live


## The last device.set_led receipt for an addr (RGB the test asserts tracks the fixture's band). {} if none.
func led_receipt(addr: int) -> Dictionary:
	return _led_receipts.get(addr, {})


## The band key an addr is bound to (SizeSortBind result) — the test asserts big->bass / small->treble.
func addr_band_key(addr: int) -> String:
	return str(_addr_band.get(addr, ""))


## The last screen frame stats { mean, variance } (variance>0 <=> non-blank).
func screen_stats() -> Dictionary:
	return _last_screen_stats


## The FreqToColor node (the test asserts warm-for-bass / cool-for-treble directly).
func freq_to_color_node():
	return _freq_to_color


func audio_is_live() -> bool:
	return _audio_live


# --- setup helpers ---------------------------------------------------------------------------------

## Build a runtime + load an arrangement file into it, parented so the tree owns it. The runtime is
## room-owned (a child of THIS demo node, which owns the room) — the same load_arrangement path the room
## itself drives, so the demo runs on real runtimes, not throwaway ones.
func _load_runtime(path: String) -> GraphRuntime:
	var rt := GraphRuntime.new()
	add_child(rt)
	rt.load_json(path)
	return rt


## The player's live position, read off the room's first-person controller (its `_pos` var). Headless
## callers pass a position into drive_once directly; live, the room integrates _pos every frame.
func _player_pos() -> Vector3:
	if room != null and is_instance_valid(room):
		var p = room.get("_pos")
		if typeof(p) == TYPE_VECTOR3:
			return p
	return Vector3.ZERO


## The minimal on-screen LED indicator (demo C): a small labelled ColorRect on its own CanvasLayer so the
## mapped device.set_led colour is VISIBLE with no real hardware. Additive — a plain swatch, top-left.
func _build_led_indicator() -> void:
	if _headless:
		return
	var layer := CanvasLayer.new()
	layer.name = "__demo_led_layer"
	layer.layer = 40
	add_child(layer)
	var box := VBoxContainer.new()
	box.position = Vector2(16, 16)
	layer.add_child(box)
	_led_label = Label.new()
	_led_label.text = "LED (demo C): device.set_led"
	_led_label.add_theme_font_size_override("font_size", 13)
	box.add_child(_led_label)
	_led_swatch = ColorRect.new()
	_led_swatch.custom_minimum_size = Vector2(120, 40)
	_led_swatch.color = Color(0.1, 0.1, 0.1)
	box.add_child(_led_swatch)


## Tint the LED swatch from a device.set_led receipt (r,g,b in 0..1). A no-op receipt (host with no LED)
## or a non-led op leaves the swatch as-is. Headless-safe (no swatch => nothing to tint).
func _apply_led(receipt: Dictionary) -> void:
	if _led_swatch == null:
		return
	if str(receipt.get("op", "")) != "device.set_led" or receipt.get("noop", false):
		return
	_led_swatch.color = Color(
		clampf(float(receipt.get("r", 0)), 0.0, 1.0),
		clampf(float(receipt.get("g", 0)), 0.0, 1.0),
		clampf(float(receipt.get("b", 0)), 0.0, 1.0))


## A visible red marker at the area centre (demo B) so the player can SEE where to walk. A plain unshaded
## red box on the floor under the area; additive geometry, not part of any arrangement.
func _place_area_marker() -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, 0.1, 1.0)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.15, 0.15)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = Vector3(AREA_CENTRE.x, 0.06, AREA_CENTRE.z)
	room.add_child(mi)


func _print_controls() -> void:
	print("[demo_interactions] Visi-sonor + Slice-5 interaction demo ready.")
	print("  E                 -> INTERACT: shows the dialogue (demo A). E/Dismiss to close.")
	print("  walk to RED marker -> opens the Area Menu (demo B); leave to close.")
	print("  LED swatch (top-L) -> LIVE analyzer band drives device.set_led (demo C). Hold B = force warm.")
	print("  P                 -> play/pause the mp3.  (audio_live=%s)" % str(_audio_live))
	print("  ESC               -> release mouse.")


# --- small vector coercers (JSON arrays -> Godot types) --------------------------------------------

func _v2(a, fallback: Vector2) -> Vector2:
	if a is Array and (a as Array).size() >= 2:
		return Vector2(float(a[0]), float(a[1]))
	return fallback

func _v3d(a, fallback: Vector3) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback
