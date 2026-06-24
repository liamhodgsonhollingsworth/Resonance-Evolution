class_name PrimContext
extends PrimChip
## A Context is the runtime realization of "communication is a module" (see
## COMMUNICATION-ARCHITECTURE.md). Like a Chip, it scopes a sub-arrangement; UNLIKE a Chip, it
## also supplies the *handler* that interprets HOW the modules inside it communicate. The SAME
## inner modules behave differently depending on the active Context — with zero change to the
## modules. Scenes, menus, simulations, and procedural generation are all Context handlers.
##
## This lives entirely in a MODULE, not the foundation: GraphRuntime gains nothing but a registry
## entry. The default handler reproduces a plain Chip exactly, so every existing arrangement is
## unaffected, and new disciplines are new handlers (new data), never foundation edits.
##
## params shape (extends Chip's { arrangement, ports }):
##   "handler":    "dataflow"|"gate"|"modulate"|"abstract"|"proximity"|"tick"|"sim"  (default "dataflow")
##   "modulation": { "<inner node id>": { "<param>": <value>, ... }, ... }   (handler "modulate")
##   "radius":     <float>   (handler "proximity": the static interaction range; default 1.0)
##   "steps":      <int>     (handlers "tick"/"sim": ticks to advance per evaluation; default 1)
##
## Handlers:
##   dataflow  — synchronous pull, topo-ordered. Identical to a Chip. (The identity case.)
##   gate      — the "powered scope" (Dreams microchip power): the WHOLE scope only propagates
##               while the implicit boolean input port "enabled" is truthy; otherwise every output
##               is null (the scene/menu/sim is dormant). "act differently depending on context."
##   modulate  — overlays per-inner-node param overrides before evaluating, so the same inner
##               modules COMPUTE DIFFERENT VALUES under different Contexts. "different properties
##               depending on what is going on." Never mutates the source arrangement.
##   abstract  — "a primitive is a node you chose not to open": compute the (pure) scope ONCE and
##               shortcut to a content-addressed cache forever after. (See the section below.)
##   proximity — the SPATIAL gate: two modules communicate only when near. The scope propagates only
##               while the two implicit "vector" input ports "pos_a" and "pos_b" are within "radius"
##               of each other; otherwise the scope is dormant (every output null), exactly like a
##               disabled gate. This is the per-pair "use X on Y" 3D interaction — the SAME scope is
##               live or dormant purely as a function of where its endpoints are. It is the first
##               handler to realize the locked direction "the observer/spatial state is just an INPUT
##               a handler reads" (the later observer-driven abstract/LOD handler reads camera
##               distance the SAME way): position is dynamic → an input port; range is static → a param.
##   tick / sim — time-stepped propagation: advance the scope "steps" ticks, where each tick evaluates
##               the scope (State nodes supply their held values — the cycle-breaking sources) and then
##               commits each State's "next" input as its new held value. The two are the SAME stepping
##               core under two SEMANTICS, selectable per context (both ship — you pick by handler):
##                 tick — CONTINUOUS / living: State persists across outer evaluations, so the sim keeps
##                        evolving frame to frame (walk away and it kept running). Real-time worlds.
##                 sim  — REPRODUCIBLE / fresh: State is re-init to params.init before each outer
##                        evaluation, so the run is a PURE function (init, inputs, steps) → output, hence
##                        content-addressable — the substrate for precompute/bake + the abstract handler.

# Process-wide memoization store for the `abstract` handler, keyed by a hermetic content-hash of
# (effective arrangement + handler + canonical inputs). Process-wide (not per-instance) so two
# Contexts wrapping the SAME pure arrangement share one computed result — the cross-instance reuse
# that makes abstraction pay off at scale (a garden's many identical plants compute once). The
# in-memory Dictionary is the MVP; a content-addressed on-disk store is its drop-in successor behind
# the same key. NON-DESTRUCTIVE: a summary is a derived cache entry beside the retained
# params.arrangement, never a replacement — the openable graph is always preserved (append-only).
static var _summaries: Dictionary = {}
# Count of REAL super.evaluate() runs through the abstract path — test observability for
# compute-once-then-shortcut (and a coarse cache-effectiveness signal). Not load-bearing.
static var _evals: int = 0

func _init() -> void:
	prim_type = "Context"

func _handler() -> String:
	return String(params.get("handler", "dataflow"))

## "gate" adds an implicit boolean "enabled" input beyond the Chip's mapped ports; "proximity" adds
## the two implicit "vector" inputs "pos_a"/"pos_b"; other handlers expose exactly the Chip's ports.
## These handler-implicit names ("enabled", "pos_a", "pos_b") are RESERVED: if a scope also maps an
## inner port of the same name, both appear here (the handler reads its own; the mapped one still
## feeds its inner site). Whether handler-implicit ports should live in a separate namespace from
## mapped ports is a cross-cutting decision deferred across the whole handler family, not settled here.
func input_ports() -> Array:
	var ports: Array = super.input_ports()
	match _handler():
		"gate":
			ports = ports.duplicate()
			ports.append({ "name": "enabled", "type": "bool" })
		"proximity":
			ports = ports.duplicate()
			ports.append({ "name": "pos_a", "type": "vector" })
			ports.append({ "name": "pos_b", "type": "vector" })
	return ports

func evaluate(inputs: Dictionary) -> Dictionary:
	match _handler():
		"gate":
			if not _truthy(inputs.get("enabled")):
				return _outputs_null()
			return super.evaluate(inputs)
		"proximity":
			if not _within_proximity(inputs):
				return _outputs_null()
			return super.evaluate(inputs)
		"tick":
			return _evaluate_sim(inputs, true)
		"sim":
			return _evaluate_sim(inputs, false)
		"modulate":
			return _evaluate_modulated(inputs)
		"abstract":
			return _evaluate_abstract(inputs)
		_:
			# "dataflow" and any unknown handler degrade to a plain Chip (forward-compatible:
			# an unrecognized future handler still runs as ordinary dataflow rather than failing).
			return super.evaluate(inputs)

# --- gate ------------------------------------------------------------------------------------

## Every declared output port -> null. The scope is dormant; nothing inside propagates.
func _outputs_null() -> Dictionary:
	var out := {}
	for p in (params.get("ports", {}) as Dictionary).get("outputs", []):
		out[String(p.get("name"))] = null
	return out

func _truthy(v) -> bool:
	if v == null:
		return false
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING:
			return v != "" and v != "false" and v != "0"
	return true

# --- proximity (the spatial gate: "use X on Y" only when near) -------------------------------

## True iff the two implicit position inputs are within `radius` of each other. The condition is
## computed entirely from INPUTS (the dynamic spatial state) and one static param (the range), so the
## SAME scope is live or dormant purely as a function of where its endpoints are — the per-pair 3D
## interaction. Fail-safe: a missing / unconnected position (null) means "not near" → dormant, so an
## unwired endpoint never spuriously fires an interaction. Distance is compared SQUARED against the
## squared radius (no sqrt — exact for the <= test and avoids a needless float op). Radius is clamped
## to >= 0 so a stray negative range degrades to "coincident only", never to its absolute value.
func _within_proximity(inputs: Dictionary) -> bool:
	var a := _as_vec(inputs.get("pos_a"))
	var b := _as_vec(inputs.get("pos_b"))
	if a.is_empty() or b.is_empty():
		return false
	# Treat an explicit null radius the same as a missing one (→ the 1.0 default), matching gate's
	# explicit-null handling — float(null) would otherwise silently become 0.0 (coincident-only).
	var rv = params.get("radius")
	var r: float = 1.0 if rv == null else maxf(0.0, Primitive.as_num(rv))
	return _vec_sq_distance(a, b) <= r * r

## Coerce a wire value to an Array of floats (the renderer-neutral position form — Phase 2.5 says
## everything over a port is serializable data, so positions are plain number arrays). A native Godot
## Vector2/3/4 (should a 3D-scene node emit one) is also accepted and flattened. null / anything else
## → [] (treated by the caller as "no position" → not near).
func _as_vec(v) -> Array:
	match typeof(v):
		TYPE_ARRAY:
			var out: Array = []
			for e in (v as Array):
				out.append(Primitive.as_num(e))
			return out
		TYPE_VECTOR2:
			return [v.x, v.y]
		TYPE_VECTOR3:
			return [v.x, v.y, v.z]
		TYPE_VECTOR4:
			return [v.x, v.y, v.z, v.w]
	return []

## Squared Euclidean distance over the MAX of the two dimensions — a lower-dim point is embedded in
## the higher-dim space with the missing components at 0 (a 2D point is a 3D point at z=0), the
## least-surprising rule, rather than silently dropping a dimension.
func _vec_sq_distance(a: Array, b: Array) -> float:
	var n: int = maxi(a.size(), b.size())
	var sum := 0.0
	for i in n:
		var ai: float = a[i] if i < a.size() else 0.0
		var bi: float = b[i] if i < b.size() else 0.0
		var d := ai - bi
		sum += d * d
	return sum

# --- tick / sim (time-stepped propagation; State is the cross-tick memory) --------------------

## Advance the scope `steps` ticks and return its mapped outputs. Reuses the inherited PERSISTENT
## inner runtime (PrimChip._sub), so State nodes keep their held values across ticks — and, for
## `tick` (persist == true), across outer evaluations too (a living sim). `sim` (persist == false)
## re-inits every State to params.init first, making each run a pure, content-addressable function.
## Each tick: evaluate the scope (State outputs are the cycle-breaking sources) → commit each State's
## "next". Outputs are then read WITHOUT a re-evaluate (State ports via current(), derived ports from
## the final tick's outputs), so an inner side-effecting node fires exactly `steps` times, never +1.
func _evaluate_sim(inputs: Dictionary, persist: bool) -> Dictionary:
	var arr: Dictionary = params.get("arrangement", {})
	# Load a DAG with the State feedback wires REMOVED so every State node is an unambiguous SOURCE
	# (indegree 0) — the inner topo-sort then always evaluates a State before its consumers, regardless
	# of node declaration order. The original feedback wires drive the separate commit step. This keeps
	# the floor's generic topo-sort untouched (no special-casing of State in GraphRuntime).
	var dag := _strip_state_feedback(arr)
	if _sub == null:
		_sub = GraphRuntime.new()
		add_child(_sub)
	var pr := get_parent()
	_sub.depth = ((pr as GraphRuntime).depth if pr is GraphRuntime else 0) + 1
	# Diff-hotload keeps existing State instances (and their held values) across calls — load never
	# resets _held — so continuity survives a reload; reproducibility is an explicit reset, not a rebuild.
	_sub.load_arrangement(dag)
	if not persist:
		_reset_states()
	# Map the scope's incoming ports to their inner sites; held constant for the whole step run.
	var ports: Dictionary = params.get("ports", {})
	var ext := {}
	for p in ports.get("inputs", []):
		var nid := String(p.get("node"))
		if not ext.has(nid):
			ext[nid] = {}
		ext[nid][String(p.get("port"))] = inputs.get(String(p.get("name")))
	_sub.set_external_inputs(ext)
	var steps: int = maxi(0, int(Primitive.as_num(params.get("steps", 1))))
	# Advance `steps` ticks. There is deliberately NO post-loop observational evaluate — that would
	# re-run the whole DAG and re-fire any inner side-effecting node, so an inner Log would log steps+1
	# times. Instead, post-step state is read directly below. (steps == 0 → no tick runs: State outputs
	# resolve to their init via current(); a derived output stays null until at least one tick runs.)
	var outs := {}
	for _i in steps:
		outs = _sub.evaluate()
		_commit_states(arr, outs)
	# Read outputs WITHOUT re-running the DAG: a State output port reports its COMMITTED held value
	# (current(), side-effect-free); any other (derived) port reflects the final tick's computed value.
	var result := {}
	for p in ports.get("outputs", []):
		var node_id := String(p.get("node"))
		var prim = _sub.nodes.get(node_id)
		if prim != null and prim.has_method("current"):
			result[String(p.get("name"))] = prim.current()
		else:
			var src: Dictionary = outs.get(node_id, {})
			result[String(p.get("name"))] = src.get(String(p.get("port")))
	return result

## A deep copy of `arr` with every wire feeding a State node's "next" port dropped, so State nodes are
## pure sources in the inner DAG. Pure data → data; never mutates the source arrangement.
func _strip_state_feedback(arr: Dictionary) -> Dictionary:
	var state_ids := {}
	for n in arr.get("nodes", []):
		if String(n.get("type")) == "State":
			state_ids[String(n.get("id"))] = true
	var out: Dictionary = arr.duplicate(true)
	var kept := []
	for w in out.get("wires", []):
		if state_ids.has(String(w.get("to"))) and String(w.get("in")) == "next":
			continue
		kept.append(w)
	out["wires"] = kept
	return out

## At a tick boundary, hand each State node the value arriving at its "next" input THIS tick (read
## from the just-computed outputs via the scope's ORIGINAL wires, feedback included). A State with no
## "next" wire holds constant. Only nodes exposing commit() (State) are touched — others are pure.
func _commit_states(arr: Dictionary, outs: Dictionary) -> void:
	var wires: Array = arr.get("wires", [])
	for node_id in _sub.nodes:
		var prim = _sub.nodes[node_id]
		if not prim.has_method("commit"):
			continue
		for w in wires:
			if String(w.get("to")) == node_id and String(w.get("in")) == "next":
				var from_id := String(w.get("from"))
				if not outs.has(from_id):
					# Broken feedback wire (the "next" source node is absent from the scope). Don't
					# silently corrupt the held value with null — warn and preserve it. A source that
					# IS present but legitimately yields null still commits below.
					push_warning("PrimContext[sim]: State '%s' next-source '%s' missing — commit skipped" % [node_id, from_id])
					break
				prim.commit((outs.get(from_id, {}) as Dictionary).get(String(w.get("out"))))
				break

## Restore every State node to params.init (the reproducible `sim` handler calls this before stepping).
func _reset_states() -> void:
	for node_id in _sub.nodes:
		var prim = _sub.nodes[node_id]
		if prim.has_method("reset_state"):
			prim.reset_state()

# --- modulate --------------------------------------------------------------------------------

## Evaluate the inner arrangement with per-node param overrides overlaid. Builds a deep COPY of
## the arrangement so the shared source spec is never mutated, swaps it in only for the duration
## of the super-eval, then restores it.
func _evaluate_modulated(inputs: Dictionary) -> Dictionary:
	var modulation: Dictionary = params.get("modulation", {})
	if modulation.is_empty():
		return super.evaluate(inputs)
	var base_arr: Dictionary = params.get("arrangement", {})
	var mod_arr := _overlay_params(base_arr, modulation)
	var saved = params.get("arrangement")
	params["arrangement"] = mod_arr
	var result: Dictionary = super.evaluate(inputs)
	params["arrangement"] = saved
	return result

## A deep copy of `arr` where each node whose id is a key in `modulation` has those params overlaid
## over its own. Pure data -> data; never touches `arr`.
func _overlay_params(arr: Dictionary, modulation: Dictionary) -> Dictionary:
	var out: Dictionary = arr.duplicate(true)
	for n in out.get("nodes", []):
		var nid := String(n.get("id"))
		if modulation.has(nid):
			var p = n.get("params", {})
			if not (p is Dictionary):
				p = {}
			for k in (modulation[nid] as Dictionary):
				p[k] = modulation[nid][k]
			n["params"] = p
	return out

# --- abstract ("a primitive is a node you chose not to open") --------------------------------

## Treat this scope as a PRIMITIVE with cached, content-addressed properties instead of re-running
## it. The first evaluation for a given content-address runs the real recursive dataflow once and
## stores the result; every later evaluation with the same key SHORTCUTS to the stored result
## (compute-once-then-shortcut). This is the runtime form of scale-independent abstraction: the
## stored result IS the scope's behavior summary, so a node built from interacting sub-nodes is
## consumed at larger scale as one coherent primitive.
##
## SOUND ONLY for a pure scope: if ANY inner node is not is_cacheable(), this DEGRADES to a plain
## Chip (runs live every time) — so abstraction never silently freezes a side effect or orphans a
## renderer-bound live instance. Re-expansion in the MVP is just "clear the cache".
func _evaluate_abstract(inputs: Dictionary) -> Dictionary:
	if not _scope_is_cacheable():
		return super.evaluate(inputs)
	var key := _cache_key(inputs)
	if _summaries.has(key):
		# Return a PRIVATE copy. The cache is process-wide and GDScript dicts are references, so
		# handing the cached dict out directly would let any future read-then-write caller corrupt
		# every other node sharing the key. Outputs are plain serializable data → the copy is cheap.
		return (_summaries[key] as Dictionary).duplicate(true)
	_evals += 1
	var fresh: Dictionary = super.evaluate(inputs)
	_summaries[key] = fresh.duplicate(true)
	return fresh

## True iff EVERY node in the scope opts in to memoization (Primitive.is_cacheable()). A throwaway
## runtime resolves each node's type to its declared cacheability — so the rule respects each
## primitive's own contract and extends automatically as new cacheable primitives are added. (An
## unknown / unresolvable type is treated as non-cacheable: fail safe.)
func _scope_is_cacheable() -> bool:
	var arr: Dictionary = params.get("arrangement", {})
	var nodes_list: Array = arr.get("nodes", [])
	if nodes_list.is_empty():
		return false
	var probe := GraphRuntime.new()
	var ok := true
	for n in nodes_list:
		var prim: Primitive = probe._instance(String(n.get("type")))
		var cacheable := prim != null and prim.is_cacheable()
		if prim != null:
			prim.free()
		if not cacheable:
			ok = false
			break
	probe.free()
	return ok

## Hermetic content-address: EVERY input that affects the output is in the key — the inner
## arrangement, the PORTS map (PrimChip.evaluate feeds inputs to inner sites and reads outputs FROM
## inner sites via params.ports, so two scopes with the same arrangement but a different port map
## compute different outputs and must NOT share a key), the "abstract:" tag (so keys never cross
## handlers), and the canonicalized inputs (so equal inputs hash equal). Reuses the same
## String.sha256_text() idiom as live_host.gd / chip_ops.gd. NOTE: this handler ignores
## params.modulation — `abstract` and `modulate` are separate match arms and must not be composed
## until the key folds in the overlay; the worst case of the JSON-stringify key (insertion-order
## sensitivity) is a missed hit, never a wrong hit. PRECONDITION (handler exclusivity): the key omits
## the handler name and handler-specific params (proximity's "radius", modulate's "modulation") — sound
## ONLY because a Context picks exactly ONE handler via _handler(), so this cache is reached solely from
## the abstract arm. If handler composition is ever added, fold handler identity + its params in here.
func _cache_key(inputs: Dictionary) -> String:
	var arr_hash := JSON.stringify(params.get("arrangement", {})).sha256_text()
	var ports_hash := JSON.stringify(params.get("ports", {})).sha256_text()
	var in_hash := _canonical_inputs(inputs).sha256_text()
	return "abstract:%s:%s:%s" % [arr_hash, ports_hash, in_hash]

## A stable string for an inputs dict: keys sorted so two equal-valued dicts produce equal strings.
func _canonical_inputs(inputs: Dictionary) -> String:
	var keys: Array = inputs.keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%s=%s" % [String(k), JSON.stringify(inputs[k])])
	return "|".join(PackedStringArray(parts))
