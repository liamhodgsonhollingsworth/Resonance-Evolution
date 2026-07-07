class_name GraphRuntime
extends Node
## Interprets an "arrangement" (a graph of primitive instances + typed wires, stored as
## plain data) into live primitive nodes, and evaluates the dataflow.
##
## RELOAD IS A DIFF, NOT A REBUILD. This is the hotload model the whole system runs on:
## change the DATA, and the already-loaded primitives are re-wired in place. Unchanged
## primitives (and any live 3D models they hold) are KEPT, their params are updated in
## place, and only added / removed / type-changed nodes are touched. No script reload.

var arrangement: Dictionary = {}
var nodes: Dictionary = {}  # node_id (String) -> Primitive

# type name -> primitive class (GDScript). New primitive TYPES register here; new
# FUNCTIONS are just new arrangements over the already-registered types.
var _registry: Dictionary = {}

# External input injection: node_id -> { in_port -> value }. Set when this runtime is a
# Chip's nested sub-graph, so the Chip can feed its incoming wire values into the inner
# nodes. Empty for a top-level runtime, so it changes nothing in the normal case.
var _external: Dictionary = {}

# Per-frame INPUT FRAME (Dreams-arc Slice 2): abstract input_id (String) -> value. This is the
# universal PORTABILITY SEAM the injector writes and PrimInput reads — the same seam a camera frame,
# an audio-band frame, or a swipe frame injects through in later slices. Distinct from `_external`
# above (which keys by node_id -> port for Chip sub-graph port injection): this keys by ABSTRACT
# input vocabulary and is read by any Input source node, wherever it sits in the graph. Empty for a
# runtime nobody feeds, so an un-driven Input just falls back to its params.default — nothing changes.
var _input_frame: Dictionary = {}

# Recursion depth in the Chip-nesting tree (0 = top level). A Chip sets its sub-runtime's
# depth to its own + 1; PrimChip caps it (PrimChip.MAX_DEPTH) so a deeply-nested or (once
# shared chip definitions exist) self-referencing chip halts gracefully instead of
# overflowing the GDScript call stack. Unused for a flat top-level graph.
var depth: int = 0

# Frame-relative fractal primitives (OPT-IN; both unset => classic flat behavior, nothing
# changes). `definitions` (a Definitions store) lets a type resolve to its LEAF or, when a
# frame descends, to its DECOMPOSITION. `descend_budget` is this v0 frame model's UNIFORM
# descent depth (every subtree observed at the same grain): at budget 0 every node is a
# primitive (its leaf); with budget > 0 a node whose type has a decomposition is replaced by
# that decomposition, recursing with budget - 1 — fractal, no privileged universal bottom. A
# richer frame (per-type / per-observer / per-region descent policy) is a later generalization;
# `Definitions.descend` already takes a plain budget, so it stays a local change. See
# `runtime/definitions.gd` and the law in CLAUDE.md.
var definitions = null
var descend_budget: int = 0

func _init() -> void:
	register("Const", PrimConst)
	# Input: the per-frame SOURCE sibling of Const (Dreams-arc Slice 2). Emits a value looked up from
	# the runtime's abstract input FRAME (set_input_frame) by params.input_id, falling back to
	# params.default. The READ end of the universal input portability seam — new arrangements, never
	# new engine code, add an input. See prim_input.gd + set_input_frame() below.
	register("Input", PrimInput)
	# Sensor: the CONTINUOUS-signal SOURCE sibling of Input (Dreams-arc Slice 4). Emits a scalar it SENSES
	# for a bound target — proximity DISTANCE (reusing PrimContext's proximity math), a sensed vector's
	# VOLUME/magnitude, or a continuous external band read from the SAME per-frame input FRAME Input reads
	# (set_input_frame, keyed by params.sensor_id — how a camera/audio-band frame drives it). New source
	# arrangement, never new engine code; unknown/absent signal falls to params.default. See prim_sensor.gd.
	register("Sensor", PrimSensor)
	register("Math", PrimMath)
	# The pure OPERATOR siblings of Math (same source shape, an op table in the DATA). Compare
	# emits a bool predicate (<,<=,==,!=,>,>=); Logic gates bools (and/or/xor/not/...); Select is
	# the MUX/ternary (cond ? a : b). Together they make "near Y AND pressed X" and if/else
	# branches single wire-able nodes — the missing operators for the interaction spine +
	# visi-sonor's BRAIN threshold logic. New arrangements, never new engine code.
	register("Compare", PrimCompare)
	register("Logic", PrimLogic)
	register("Select", PrimSelect)
	register("Log", PrimLog)
	register("Model", PrimModel)
	register("Transform", PrimTransform)
	register("Group", PrimGroup)
	# A Chip is itself a primitive whose params hold a nested arrangement. Registering it
	# in every runtime (including a Chip's own sub-runtime) makes nesting recursive for
	# free — "procedural all the way down" with no special-casing.
	register("Chip", PrimChip)
	# Conversation/idea node: one chat turn or one idea, as DATA. A nonlinear conversation
	# is an arrangement of these wired reply -> parent; context is assembled by walking the
	# wires (see ConvoProtocol), not by dataflow.
	register("Message", PrimMessage)
	# Context: a Chip that also supplies the HANDLER for how its scoped modules communicate
	# (dataflow / gate / modulate / ...). The realization of "communication is a module" — see
	# COMMUNICATION-ARCHITECTURE.md. Default handler == a plain Chip, so this changes nothing for
	# existing graphs; new disciplines are new handlers (data), never foundation edits.
	register("Context", PrimContext)
	# State: the one stateful module — a unit-delay holding a value across ticks. The substrate for
	# the tick/sim Context handlers (continuous + reproducible time-stepping). Like every other type
	# this is just a registry entry; the time-stepping discipline lives entirely in the Context module.
	register("State", PrimState)
	# EffectStack: emits a renderer-NEUTRAL ordered list of post-process effect layers as DATA (the
	# painterly look as an arrangement). Like Model emits scene_node data for a swappable 3D delegate,
	# this emits effect_stack data for a swappable 2D delegate (EffectStackCpu now; GPU/three.js later).
	# A new painterly effect is a new layer TYPE a delegate learns, never a new primitive — see
	# PROGRESS.md item #1 + COMMUNICATION-ARCHITECTURE.md (composition-as-data).
	register("EffectStack", PrimEffectStack)
	# View: emits a renderer-NEUTRAL glTF-2.0-camera descriptor as DATA (the camera as an
	# arrangement, not a hardcoded Camera3D). Like Model emits scene_node data for a swappable 3D
	# delegate, this emits `view` data the renderer delegate (GodotSceneRenderer) turns into a live
	# Camera3D — and the glTF exporter turns into a glTF camera node, so the same single-scene view
	# is portable to three.js / <model-viewer> / Blender. The "single scene -> static view" keystone.
	register("View", PrimView)
	# Environment: emits a renderer-NEUTRAL sky/environment descriptor as DATA (the always-on iterable
	# sky as an arrangement, not a host-side sibling config block). Like View emits `view` data the
	# renderer delegate turns into a live Camera3D, this emits `environment` data GodotSceneRenderer
	# turns into a live Environment + Sky + sun. The sky is now a NODE on a wire, diff-hotloaded with
	# the scene, and portable (a three.js delegate reads the same descriptor). See prim_environment.gd.
	register("Environment", PrimEnvironment)
	# Light: emits a renderer-NEUTRAL glTF-KHR_lights_punctual light descriptor as DATA (a light as an
	# arrangement, not a hardcoded DirectionalLight3D). The renderer delegate (apply_lights) builds the
	# live Godot light; a glTF exporter turns it into a KHR_lights_punctual node. See prim_light.gd.
	register("Light", PrimLight)
	# --- The SUPERVISED PAINTERLY EVOLVER as an arrangement (GZ-EVOLVE.1) -----------------------------
	# The human-in-loop evolver loop is itself a NODE SYSTEM, not new engine logic: four primitives wired
	# as DATA. The genomes + the evolver's OWN params (the meta_genome) live entirely in node params, so
	# the evolver evolves through use and a new gene/operator/button is additive (a library entry / an
	# action id), never a foundation edit. See EVOLVER-LOOP.md.
	#   EvolverPopulation — holds one generation of EvolverGenomes + the meta_genome, emits `population`.
	#   Render2D          — genome → PNG thumbnail via EffectStackCpu over a fixed source, emits `rendered`.
	#   ApertureSurface   — the human-in-loop fitness seam: push cards (X/Evolve/Save) + read back actions.
	#   Breed             — KEEP/CROSSOVER/INJECT a decided generation into the next `population`.
	register("EvolverPopulation", PrimEvolverPopulation)
	register("Render2D", PrimRender2D)
	register("ApertureSurface", PrimApertureSurface)
	register("Breed", PrimBreed)
	# --- The SCREEN / VIDEO family (Visi-sonor Wave 1D, item 10 core) ---------------------------------
	# A TV/screen in the room + a video frame provider, both as renderer-NEUTRAL DATA (no projection
	# mapping). VideoSource decodes a video to a per-frame texture (PNG-path on the wire, PrimRender2D's
	# portability invariant) and syncs its playhead to an external mp3 playhead; Screen is a flat quad
	# whose albedo texture is that video frame (music_video) OR an audio-driven classic viz. A missing
	# media file degrades to a synthetic animated pattern (C-ideal), never a crash. New arrangements,
	# never new engine code, add a screen. See prim_video_source.gd + prim_screen.gd.
	register("VideoSource", PrimVideoSource)
	register("Screen", PrimScreen)
	# --- The PROJECTION-MAPPING family (projection-sim foundation) ------------------------------------
	# A simulated projector + camera-feedback calibration, all as DATA (the shared substrate the
	# drum-teaching / laser / projection-audio-sync arcs inherit). CPU math seam: runtime/projection_math.gd.
	register("Projector", PrimProjector)
	register("ProjectionSurface", PrimProjectionSurface)
	register("CalibrationPattern", PrimCalibrationPattern)
	register("ProjectionMap", PrimProjectionMap)
	register("ProjectionObserve", PrimProjectionObserve)
	register("ProjectionCalibration", PrimProjectionCalibration)
	# TemporalOffsetEstimate: the TEMPORAL analog of the spatial homography step, for LIGHT CALIBRATION
	# (visi-sonor 3B, item 5). Cross-correlates a commanded light's emitted-pulse timeline vs its camera-
	# observed brightness timeline -> latency ms, and packs the per-light correction record (timing/color/
	# intensity) transports ride under device.*. Re-uses the SAME observe->calibrate loop for the spatial
	# offset; this adds only the time axis. Additive registered TYPE. See prim_temporal_offset_estimate.gd.
	register("TemporalOffsetEstimate", PrimTemporalOffsetEstimate)
	# StereoRender: ONE viewing-geometry parameter set (viewer distance / IPD / focal plane /
	# depth budget / screen DPI, all DATA on the wire) drives MULTIPLE stereo output modes from
	# the same scene — depth map, autostereogram (SIRDS), stereo pair, anaglyph — and the same
	# dict drives the live/VR camera rig (renderers/stereo_rig.gd). CPU + headless-decodable;
	# see notes/design/stereogram_vr_viewer_2026-07-02.md.
	register("StereoRender", PrimStereoRender)
	# TextureApply: emits renderer-neutral set_material ops (the node-based live-texturing driver
	# for the sandbox's _apply_material seam) — see primitives/prim_texture_apply.gd.
	register("TextureApply", PrimTextureApply)
	register("MathPaint", PrimMathPaint)
	register("LSystem", PrimLSystem)
	# SdfEdit: one signed-distance-field edit (shape + transform + CSG op + blend + material) as
	# DATA, emitting an EDIT-LIST descriptor a chain of these nodes accumulates. Like LSystem it is a
	# param-generator that emits renderer-neutral data through a pure math module (renderers/sdf.gd);
	# it STOPS at DATA — a later sculpt/voxel/splat slice bakes the field. New shapes/ops are new
	# enum strings a consumer learns, never engine edits.
	register("SdfEdit", PrimSdfEdit)
	# The Godot Aperture 3D surface (godot/aperture/): inbox READ + action WRITE over the
	# same substrate/channels the web board uses - see prim_aperture_inbox/action.gd.
	register("ApertureInbox", PrimApertureInbox)
	register("ApertureAction", PrimApertureAction)
	# WorldAction: the param-configured side-effect SINK (Dreams-arc Slice 1). Sibling of
	# ApertureAction — a thin wire around the WorldActions op registry (runtime/world_actions.gd).
	# A new world effect is a registered op, never a new primitive; unknown op = a declared no-op
	# so the same arrangement runs on any host. See prim_world_action.gd + world_actions.gd.
	register("WorldAction", PrimWorldAction)
	# CompareDiff: the ONE convergence COMPARATOR (Dreams-arc Slice 6). Reads a candidate + a reference
	# and emits a single scalar distance `d` selected by params.metric from a PLUGGABLE metric table
	# (dict_equality / l2 / abs now; image metrics register against the SAME seam later). The shared
	# measurement node under the Lathe blue-green swap, the image evolver, module-parity verification,
	# and GD≡Py≡JS parity — all "score candidate vs reference". Unknown metric = a declared +INF sentinel,
	# so the same arrangement runs on any host. New arrangement/metric, never engine code. See
	# prim_compare_diff.gd.
	register("CompareDiff", PrimCompareDiff)
	# --- The AUDIO ANALYSIS chain (visi-sonor arc, Slice 1A) ------------------------------------------
	# The MUSIC-INPUT head every effect + light reads: prim_audio_source -> prim_spectrum ->
	# prim_spectrum_bands -> (a host injector writes) set_input_frame(signal.band.low/mid/high). All THREE
	# are NEW source-category types (siblings of Input/Sensor), never edits to an existing primitive; the
	# seam is GENERAL (source_kind=mp3|stream|mic|loopback) but ONLY mp3 is wired — the rest are declared
	# no-ops, so a future source is a new injector into the SAME frame keys, not engine code. Bands are
	# plain float DATA on wires (T ideal), so any downstream node subscribes. See prim_audio_source.gd /
	# prim_spectrum.gd / prim_spectrum_bands.gd.
	#   AudioSource   — mode=mp3 owns an AudioStreamPlayer on a dedicated bus; emits pcm_stream + playhead.
	#   Spectrum      — wraps Godot's built-in AudioEffectSpectrumAnalyzer on that bus -> N log-spaced,
	#                   EMA-smoothed bands (no custom FFT).
	#   SpectrumBands — folds the raw bands into named sub/bass/lowmid/mid/highmid/treble + low/mid/high.
	register("AudioSource", PrimAudioSource)
	register("Spectrum", PrimSpectrum)
	register("SpectrumBands", PrimSpectrumBands)
	# --- The FREQ-MAPPING + UNIVERSAL BIND cluster (visi-sonor light-show Slice 1B, items 6+8) --------
	# The binding seam that unifies lighting (items 2/3/6) and screen effects (item 7) into ONE operation:
	# a light's brightness and a visual bar's height are BOTH a bound feature. All renderer-neutral DATA
	# on wires (T), all NEW types (N — no primitive edits), all "unknown/absent input = declared no-op" (C).
	#   FeaturePick     — route any {sub..treble/energy/centroid/flux/beat/tempo_phase} off the band frame.
	#   EnvelopeFollower — asymmetric attack/release "fall" smoother (the substrate's stateful kind).
	#   ResponseCurve   — reusable shaping curve (linear/exp/log/s) as DATA; static shape_value() shared.
	#   ParamBind       — the highest-leverage node: normalize -> curve -> envelope -> gate -> remap.
	#   FreqToColor     — bass->warm / treble->cool ramp (+ pitch_class); ONE relinkable palette by handle.
	#   SizeSortBind    — monotone size->frequency auto-assign (big fixtures->bass, small->treble).
	# See prim_feature_pick/prim_envelope_follower/prim_response_curve/prim_param_bind/prim_freq_to_color/
	# prim_size_sort_bind.gd + headless_freq_map_test.gd.
	register("FeaturePick", PrimFeaturePick)
	register("EnvelopeFollower", PrimEnvelopeFollower)
	register("ResponseCurve", PrimResponseCurve)
	register("ParamBind", PrimParamBind)
	register("FreqToColor", PrimFreqToColor)
	register("SizeSortBind", PrimSizeSortBind)
	# --- The FIXTURE / ROOM-ASSET family (visi-sonor arc Slice 1C, item 3) ---------------------------
	# AssetImport: a thin front-end over the lazy asset manifest that emits a Model-shaped scene_node
	# for a library asset BY ID — and, when the referenced GLB is absent/unknown, falls back to a
	# placeholder box/cylinder mesh (the C-ideal: a fixture references a not-yet-downloaded lighting
	# asset and still renders + tests headless, never crashing, silently upgrading when the GLB lands).
	register("AssetImport", PrimAssetImport)
	# LedStrip: an array of prim_light descriptors along a path — a controllable, per-pixel-addressable
	# LED strip drivable by BOTH the 3D renderer (lights port) AND a real WLED (set_led port). It REUSES
	# PrimLight per pixel; a new strip is a new arrangement, never an engine edit. See prim_led_strip.gd.
	register("LedStrip", PrimLedStrip)
	# --- Visi-sonor Wave 3A: DMX/LIGHTING TRANSPORT substrate (item 2 — the real hardware seam). ---
	# ADDITIVE primitive TYPES: a DMX/pixel framebuffer, a fixture descriptor, a logical->channel map,
	# and a zero-hardware virtual-strip sink. The real transport SINKS (DDP/WLED over UDP; Art-Net/sACN
	# declared no-ops) are NOT primitives — they register as NEW device.* host ops via runtime/transports/*
	# so device.set_led stays untouched (N-ideal). A universe/fixture/colour is plain DATA on a wire.
	register("DmxUniverse", PrimDmxUniverse)   # 512-ch / pixel framebuffer. See prim_dmx_universe.gd.
	register("Fixture", PrimFixture)           # OFL/GDTF-style fixture descriptor. See prim_fixture.gd.
	register("ChannelMap", PrimChannelMap)     # logical (r,g,b,dimmer) -> universe channels. See prim_channel_map.gd.
	register("LightSim", PrimLightSim)         # zero-hardware virtual strip sink. See prim_light_sim.gd.

func register(type_name: String, prim_class) -> void:
	_registry[type_name] = prim_class

## Load / replace the arrangement via a diff against the current graph.
func load_arrangement(data: Dictionary) -> void:
	var new_specs := {}
	for n in data.get("nodes", []):
		new_specs[String(n.get("id"))] = n

	# Remove nodes that disappeared or whose type changed.
	for id in nodes.keys():
		var keep: bool = new_specs.has(id) and String(new_specs[id].get("type")) == nodes[id].prim_type
		if not keep:
			nodes[id].queue_free()
			nodes.erase(id)

	# Add new nodes; update params on kept nodes (preserves live instances / models).
	for id in new_specs.keys():
		var spec: Dictionary = new_specs[id]
		if nodes.has(id):
			nodes[id].params = spec.get("params", {})
		else:
			var prim: Primitive = _instance(String(spec.get("type")))
			if prim == null:
				push_warning("GraphRuntime: unknown primitive type '%s'" % spec.get("type"))
				continue
			prim.name = id
			prim.params = spec.get("params", {})
			add_child(prim)
			nodes[id] = prim

	arrangement = data

func _instance(type_name: String) -> Primitive:
	# A definition store, when attached, supersedes the built-in registry for leaf lookup —
	# so types defined only in the store resolve, while the default registry stays untouched.
	if definitions != null and definitions.has_leaf(type_name):
		var lc = definitions.leaf_class(type_name)
		if lc != null:
			return lc.new()
	var c = _registry.get(type_name)
	if c == null:
		return null
	return c.new()

## Inject external input values for the next evaluate() (node_id -> { in_port -> value }).
## Used by a Chip to feed its incoming port values into its nested sub-graph.
func set_external_inputs(ext: Dictionary) -> void:
	_external = ext

## Inject the per-frame INPUT FRAME for subsequent evaluate()s (abstract input_id -> value). This is
## the universal portability seam (Dreams-arc Slice 2): a per-host INJECTOR deposits one frame of
## abstract inputs here and every Input source node reads its own input_id out of it. The SAME seam a
## later camera / audio-band / swipe injector writes through. Purely additive — it stores the frame;
## evaluate()'s topo/dataflow is unchanged, and an Input whose key is absent falls to params.default.
func set_input_frame(frame: Dictionary) -> void:
	_input_frame = frame

## The current per-frame input frame (abstract input_id -> value). PrimInput.evaluate() reads this off
## its parent runtime; a host / test can also inspect what was last injected. Read-only accessor —
## the frame is only mutated through set_input_frame, so Input nodes never touch runtime internals.
func get_input_frame() -> Dictionary:
	return _input_frame

## Resolve the declared semantic type of a primitive type's port (e.g. ("Math","a",true)
## -> "number"). Drives Chip boundary-port typing and GraphEdit slot colors. Returns
## "any" for unknown types/ports (and for Chip, whose ports live in instance params).
func port_type(type_name: String, port_name: String, is_input: bool) -> String:
	var prim := _instance(type_name)
	if prim == null:
		return "any"
	var ports: Array = prim.input_ports() if is_input else prim.output_ports()
	for p in ports:
		if String(p.get("name")) == port_name:
			return String(p.get("type", "any"))
	return "any"

## Editor support: the input & output ports of a node SPEC, as { "inputs": [{name,type}],
## "outputs": [{name,type}] }. Params are applied first so a Chip reports its instance ports
## (which live in params.ports); for fixed-port primitives params are simply ignored.
func ports_of(node: Dictionary) -> Dictionary:
	var prim := _instance(String(node.get("type")))
	if prim == null:
		return { "inputs": [], "outputs": [] }
	prim.params = node.get("params", {})
	return { "inputs": prim.input_ports(), "outputs": prim.output_ports() }

## Evaluate the whole dataflow once. Returns node_id -> { output_port -> value }.
func evaluate() -> Dictionary:
	var outputs := {}
	var wires: Array = arrangement.get("wires", [])
	for node_id in _topo_order():
		var prim: Primitive = nodes[node_id]
		var inputs := {}
		# Seed any externally-injected inputs first (Chip ports); real wires override.
		var ext: Dictionary = _external.get(node_id, {})
		for k in ext:
			inputs[k] = ext[k]
		for w in wires:
			if String(w.get("to")) == node_id:
				var src: Dictionary = outputs.get(String(w.get("from")), {})
				inputs[String(w.get("in"))] = src.get(String(w.get("out")))
		# Frame-relative descent: if this type has a decomposition and the frame still has
		# descent budget, observe it DECOMPOSED (its arrangement) rather than as a leaf. The
		# leaf still defines the type's I/O contract; the decomposition must honor it.
		if descend_budget > 0 and definitions != null and definitions.has_decomposition(prim.prim_type):
			outputs[node_id] = definitions.descend(prim.prim_type, inputs, descend_budget - 1)
		else:
			outputs[node_id] = prim.evaluate(inputs)
	return outputs

# Kahn topological sort over the wire DAG; cycle remnants are appended (never dropped).
func _topo_order() -> Array:
	var ids: Array = nodes.keys()
	var indeg := {}
	var adj := {}
	for id in ids:
		indeg[id] = 0
		adj[id] = []
	for w in arrangement.get("wires", []):
		var f := String(w.get("from"))
		var t := String(w.get("to"))
		if nodes.has(f) and nodes.has(t):
			(adj[f] as Array).append(t)
			indeg[t] += 1
	var queue := []
	for id in ids:
		if indeg[id] == 0:
			queue.append(id)
	var order := []
	while not queue.is_empty():
		var n = queue.pop_front()
		order.append(n)
		for m in adj[n]:
			indeg[m] -= 1
			if indeg[m] == 0:
				queue.append(m)
	for id in ids:
		if not order.has(id):
			order.append(id)
	return order

## Convenience: load an arrangement from a JSON file (res:// or user://).
func load_json(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		load_arrangement(data)
	else:
		push_error("GraphRuntime: failed to parse arrangement JSON '%s'" % path)
