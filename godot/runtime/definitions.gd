class_name Definitions
extends RefCounted
## The DEFINITION STORE — the data structure that embodies the core law: there are no
## fundamental primitives.
##
## Every TYPE carries:
##   - a LEAF behavior (a GDScript `Primitive` class), ALWAYS — the type's operational
##     behavior and I/O contract at the base frame. This is what `GraphRuntime._registry`
##     holds today. A leaf is mandatory: it is what actually computes, and what any
##     decomposition must stay faithful to.
##   - optionally, a DECOMPOSITION (an arrangement + a port map — a Chip's shape): the SAME
##     type re-expressed as an arrangement of OTHER types, seen only when a frame descends
##     into it. A type without a decomposition is simply atomic at every frame.
##
## "No fundamental primitives" means no PRIVILEGED/absolute primitive, NOT "no leaves":
## primitiveness is FRAME-RELATIVE. At a shallow frame a type is observed as its leaf; descend
## a frame and (if it has one) it is replaced by its decomposition — which may itself decompose,
## and so on (fractal, "turtles all the way down"), terminating at whatever operational leaves
## remain at the chosen depth. No universal bottom is forced.
##
## Decompositions can be attached RETROACTIVELY: registering one for a type makes every
## existing instance of that type descendable, with NO edit to any arrangement that uses it.
##
## SCOPE (v0): this store drives frame descent through the dataflow graph. It does NOT yet
## reach across a `PrimChip` boundary — a Chip's nested graph currently evaluates at its own
## (base) frame, because `PrimChip` does not propagate the store/budget into its sub-runtime.
## Unifying the Chip channel and the decomposition channel into ONE mechanism ("every node
## Chip-like") is the next, coordinated step (see HANDOFF-no-fundamental-primitives.md).
##
## This store changes nothing by itself — a `GraphRuntime` consults it only when one is
## attached and the frame has descent budget (see `GraphRuntime.descend_budget`). Absent
## that, behavior is identical to the classic flat registry.

# type name -> GDScript `Primitive` class (the operational leaf at the bottom of a frame).
var _leaves: Dictionary = {}
# type name -> { "arrangement": {nodes,wires}, "ports": {inputs:[...], outputs:[...]} }.
# `ports` binds the type's OUTER ports to inner (node, port) sites — the same shape a Chip's
# `params.ports` uses, so feeding inputs / reading outputs follows the Chip port-mapping form.
var _decomps: Dictionary = {}

## Register a type's operational leaf behavior (a `Primitive` subclass).
func register_leaf(type_name: String, prim_class) -> void:
	_leaves[type_name] = prim_class

## Attach (retroactively) a decomposition to a type. `arrangement` is a normal arrangement
## over other types; `ports` maps this type's outer ports to inner sites. Append-only in
## spirit: re-registering is a new version, never an in-place edit of an arrangement.
func register_decomposition(type_name: String, arrangement: Dictionary, ports: Dictionary) -> void:
	_decomps[type_name] = { "arrangement": arrangement, "ports": ports }

func has_leaf(type_name: String) -> bool:
	return _leaves.has(type_name)

func leaf_class(type_name: String):
	return _leaves.get(type_name)

func has_decomposition(type_name: String) -> bool:
	return _decomps.has(type_name)

## Evaluate a type's DECOMPOSITION for the given inputs, allowed to descend `budget` further
## frames. Runs a sub-runtime over the decomposition arrangement — carrying this same store
## and the remaining budget, so inner decompositions keep unfolding — and maps the outer
## inputs/outputs through the type's port bindings (the same port-binding shape `PrimChip`
## uses for its nested graph).
##
## NOTE: this mirrors `PrimChip.evaluate`'s port-feeding loop rather than sharing it, and uses
## a throwaway sub-runtime (no diff-hotload caching — a perf cost only if a decomposition holds
## a live Model). Folding both into ONE shared nested-eval mechanism ("Chip stops being
## special") is the coordinated unification deferred to the in-flight session — see
## HANDOFF-no-fundamental-primitives.md.
func descend(type_name: String, inputs: Dictionary, budget: int) -> Dictionary:
	var d: Dictionary = _decomps.get(type_name, {})
	var arrangement: Dictionary = d.get("arrangement", {})
	var ports: Dictionary = d.get("ports", {})
	var sub := GraphRuntime.new()
	sub.definitions = self
	sub.descend_budget = budget
	sub.load_arrangement(arrangement)
	# Feed outer inputs into their mapped inner (node, port) sites (a name may map to several).
	var ext := {}
	for p in ports.get("inputs", []):
		var nid := String(p.get("node"))
		if not ext.has(nid):
			ext[nid] = {}
		ext[nid][String(p.get("port"))] = inputs.get(String(p.get("name")))
	sub.set_external_inputs(ext)
	var outs := sub.evaluate()
	# Read the type's outgoing ports from their mapped inner sites.
	var result := {}
	for p in ports.get("outputs", []):
		var src: Dictionary = outs.get(String(p.get("node")), {})
		result[String(p.get("name"))] = src.get(String(p.get("port")))
	sub.free()
	return result
