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
