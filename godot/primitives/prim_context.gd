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
##   "handler":    "dataflow" | "gate" | "modulate"   (default "dataflow" == an ordinary Chip)
##   "modulation": { "<inner node id>": { "<param>": <value>, ... }, ... }   (handler "modulate")
##
## Handlers:
##   dataflow  — synchronous pull, topo-ordered. Identical to a Chip. (The identity case.)
##   gate      — the "powered scope" (Dreams microchip power): the WHOLE scope only propagates
##               while the implicit boolean input port "enabled" is truthy; otherwise every output
##               is null (the scene/menu/sim is dormant). "act differently depending on context."
##   modulate  — overlays per-inner-node param overrides before evaluating, so the same inner
##               modules COMPUTE DIFFERENT VALUES under different Contexts. "different properties
##               depending on what is going on." Never mutates the source arrangement.

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

## "gate" adds an implicit boolean "enabled" input beyond the Chip's mapped ports; other handlers
## expose exactly the Chip's ports.
func input_ports() -> Array:
	var ports: Array = super.input_ports()
	if _handler() == "gate":
		ports = ports.duplicate()
		ports.append({ "name": "enabled", "type": "bool" })
	return ports

func evaluate(inputs: Dictionary) -> Dictionary:
	match _handler():
		"gate":
			if not _truthy(inputs.get("enabled")):
				return _outputs_null()
			return super.evaluate(inputs)
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
## sensitivity) is a missed hit, never a wrong hit.
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
