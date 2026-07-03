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
	register("Math", PrimMath)
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
	# --- The PROJECTION-MAPPING family (projection-sim foundation) ------------------------------------
	# A simulated projector + camera-feedback calibration, all as DATA (the shared substrate the
	# drum-teaching / laser / projection-audio-sync arcs inherit). CPU math seam: runtime/projection_math.gd.
	register("Projector", PrimProjector)
	register("ProjectionSurface", PrimProjectionSurface)
	register("CalibrationPattern", PrimCalibrationPattern)
	register("ProjectionMap", PrimProjectionMap)
	register("ProjectionObserve", PrimProjectionObserve)
	register("ProjectionCalibration", PrimProjectionCalibration)
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
	# The Godot Aperture 3D surface (godot/aperture/): inbox READ + action WRITE over the
	# same substrate/channels the web board uses - see prim_aperture_inbox/action.gd.
	register("ApertureInbox", PrimApertureInbox)
	register("ApertureAction", PrimApertureAction)

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
