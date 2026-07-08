class_name PrimEffectRegistry
extends Primitive
## The EFFECTS-LIBRARY BACKEND registry (visi-sonor light-show Slice 2B, item 7) — the UI-INDEPENDENT
## store the effects menu reads. A new reactive-viz effect (spectrum_bars, waveform, reactive_shape,
## particles, flash, …) is a NEW REGISTRATION here, never an edit of this node or of the menu view
## (N-ideal: node-not-edit; functionality lives in the registration DATA, not in engine branches).
##
## WHY A REGISTRY (not a hardcoded list): the menu must DISCOVER effects at runtime so Slice 2A's concrete
## effect classes register themselves independently (parallel builds, zero coupling). This node holds the
## registrations as plain DATA and emits them on a wire; prim_effect_menu_view is JUST a VIEW over that
## DATA. The effects themselves are wired in the graph as ordinary prims — the registry only NAMES them so
## the menu can select/preview one.
##
## A registration is renderer-neutral DATA (T ideal):
##   { "type": "<primitive/arrangement type name>",   # the subgraph factory the menu instantiates on select
##     "defaults": { … effect param defaults … },      # the tile's initial knob values
##     "thumbnail": "res://…png"? }                     # optional preview image path (DATA, not a live texture)
##
## PERSISTENCE across re-instantiation: primitives are recreated whenever load_arrangement diffs the graph,
## so the registration set is kept in a STATIC store keyed by params.registry_id. That lets a registration
## made by one node (or a 2A effect registering itself at boot) be read by the menu-view node in the SAME
## registry namespace, and survive a graph reload. Different registry_ids are isolated (parallel menus).
##
## params:
##   registry_id  the namespace key (default "default"). Nodes sharing an id share the registration set.
##   effects      OPTIONAL declarative seed: { effect_id -> registration }. evaluate() folds these into the
##                store (additive) so an arrangement can seed the registry from data — a new effect is a new
##                row in this dict, node-not-edit.
##
## inputs:  (none required) — the registry is state, not a per-frame wire input.
## outputs:
##   registry  the full { effect_id -> registration } dict (plain DATA on the wire — T ideal).
##   ids       the sorted Array of registered effect_ids (the menu's enumeration source).

## The STATIC per-namespace store: registry_id -> { effect_id -> registration }. Static so a registration
## survives node re-instantiation (load_arrangement recreates prims) and is shared across nodes with the
## same registry_id — the discovery seam a 2A effect registers itself into. Purely ADDITIVE writes.
static var _stores: Dictionary = {}

func _init() -> void:
	prim_type = "EffectRegistry"

func output_ports() -> Array:
	return [
		{ "name": "registry", "type": "any" },
		{ "name": "ids", "type": "any" },
	]

## The namespace this node reads/writes. Defaults to "default" so a bare node still works (C ideal).
func _registry_id() -> String:
	return str(params.get("registry_id", "default"))

## The live store dict for this namespace, created empty on first touch (never null — C ideal).
static func _store_for(registry_id: String) -> Dictionary:
	if not _stores.has(registry_id):
		_stores[registry_id] = {}
	return _stores[registry_id]

## ADDITIVE registration: add/replace ONE effect by id. A new effect is a new row; re-registering the same
## id cleanly replaces its registration (defaults update) without duplicating — the node-not-edit contract.
## The registration is stored as a duplicated DICT so the caller's object is never aliased into the store.
func register_effect(effect_id: String, registration: Dictionary) -> void:
	if effect_id == "":
		return   # an unnamed effect is a declared no-op, never an error
	var store := _store_for(_registry_id())
	store[effect_id] = registration.duplicate(true)

## Remove one registration by id (append-safe: absent id = no-op). Kept for completeness / test isolation.
func unregister_effect(effect_id: String) -> void:
	var store := _store_for(_registry_id())
	store.erase(effect_id)

## Clear THIS namespace's registrations (used to start a deterministic test / rebuild a menu). Only the
## node's own registry_id is affected — parallel namespaces are untouched.
func clear() -> void:
	_stores[_registry_id()] = {}

func evaluate(_inputs: Dictionary) -> Dictionary:
	var store := _store_for(_registry_id())

	# Fold any declarative params.effects seed into the store (additive) — an arrangement can seed the
	# registry from DATA. Each entry is a new/replaced row; existing rows for other ids are untouched.
	var seed = params.get("effects", null)
	if seed is Dictionary:
		for eid in (seed as Dictionary).keys():
			var r = (seed as Dictionary)[eid]
			if r is Dictionary and String(eid) != "":
				store[String(eid)] = (r as Dictionary).duplicate(true)

	# Emit the full registry + a stable sorted id list (the menu's enumeration source). Duplicated so a
	# downstream consumer can never mutate the store through the wire (T: plain DATA, no shared handle).
	var ids: Array = store.keys()
	ids.sort()
	return { "registry": store.duplicate(true), "ids": ids }

## Impure: the output depends on the static registration store (mutated by register_effect / boot-time
## self-registration), not just params — so opt out of memoization like the other stateful prims.
func is_cacheable() -> bool:
	return false
