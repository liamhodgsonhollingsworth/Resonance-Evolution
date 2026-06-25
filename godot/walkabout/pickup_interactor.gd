class_name PickupInteractor
extends Node3D
## Proximity-gated "use / pick up" interaction for the walkabout, built ENTIRELY on the existing
## `proximity` Context handler (primitives/prim_context.gd) — this file USES that handler, it never
## edits it. The rule "the observer/spatial state is just an INPUT a handler reads" is the whole
## mechanism here: each pickable object owns one Context(handler="proximity") whose two implicit
## vector inputs are fed the player position (pos_a, dynamic) and the object position (pos_b,
## dynamic) every frame, with the interaction radius as the Context's static `radius` param. The
## scope is LIVE (emits a non-null "available" signal) only while the two positions are within
## radius, and DORMANT (null) otherwise — so "you can interact only when you walk up to it" falls
## straight out of the handler with no new gating logic.
##
## On a "use" press the nearest currently-available object is picked up (removed from the live
## scene + counted in the inventory). Everything the handler sees is renderer-neutral number arrays
## (Phase 2.5: a position over a port is plain serializable data), so this stays portable.
##
## Headless/test use: the per-frame work is split into pure methods (`refresh(player_pos)`,
## `available_ids()`, `use_nearest()`) that a headless test drives directly without a window or
## input device. `_process` only wires real Input + the live player Node3D to those methods.

const DEFAULT_RADIUS := 2.5   # meters: how close the player must be to interact

## One registered pickable: the live scene Node3D, its proximity Context runtime, and bookkeeping.
class Pickable:
	var id: String
	var node: Node3D                # the live renderer node (what gets hidden on pickup)
	var runtime: GraphRuntime      # a GraphRuntime holding this object's proximity Context
	var radius: float
	var picked := false
	var available := false         # within radius this refresh?

var _pickables: Array[Pickable] = []
var _inventory: Array[String] = []     # ids picked up, in order
var _player: Node3D = null             # set in walkabout; the body whose position gates proximity

# --- registration -----------------------------------------------------------------------------

## Register a live scene node as pickable. Builds a Context(handler="proximity") whose scope emits
## a constant "available" signal, gated by the player<->object distance. The Context lives in its
## OWN tiny GraphRuntime so each object is independent; positions are injected as external inputs.
func register(id: String, node: Node3D, radius: float = DEFAULT_RADIUS) -> void:
	var p := Pickable.new()
	p.id = id
	p.node = node
	p.radius = radius
	p.runtime = GraphRuntime.new()
	add_child(p.runtime)
	p.runtime.load_arrangement(_proximity_arrangement(radius))
	_pickables.append(p)

## The renderer-neutral interaction arrangement: a proximity Context wrapping a single Const that
## emits 1 when the scope is live. The Context exposes one output "available" (mapped to the Const)
## and, by virtue of handler="proximity", two implicit vector inputs "pos_a"/"pos_b". When the
## endpoints are within `radius`, "available" == 1; otherwise the scope is dormant and it is null.
func _proximity_arrangement(radius: float) -> Dictionary:
	return {
		"format": "resonance.arrangement/v1", "name": "pickup_proximity",
		"nodes": [{
			"id": "use", "type": "Context",
			"params": {
				"handler": "proximity", "radius": radius,
				"arrangement": { "nodes": [{ "id": "c", "type": "Const", "params": { "value": 1 } }], "wires": [] },
				"ports": { "inputs": [], "outputs": [{ "name": "available", "type": "number", "node": "c", "port": "value" }] }
			}
		}],
		"wires": []
	}

# --- the proximity refresh (pure: drive it from a test OR from _process) -----------------------

## Recompute availability for every pickable given the player's current position. For each object we
## inject pos_a (player) + pos_b (object) into its proximity Context and evaluate — `available` is
## non-null iff within radius. A picked-up object is skipped (it is gone from the world). Returns the
## number currently available.
func refresh(player_pos: Vector3) -> int:
	var count := 0
	for p in _pickables:
		if p.picked:
			p.available = false
			continue
		var obj_pos: Vector3 = p.node.global_position if is_instance_valid(p.node) else Vector3.INF
		p.runtime.set_external_inputs({
			"use": { "pos_a": [player_pos.x, player_pos.y, player_pos.z],
					 "pos_b": [obj_pos.x, obj_pos.y, obj_pos.z] }
		})
		var out: Dictionary = p.runtime.evaluate()
		var available = out.get("use", {}).get("available")
		p.available = (available != null)
		if p.available:
			count += 1
	return count

## Ids of every pickable currently within interaction range (and not already picked up).
func available_ids() -> Array:
	var out: Array = []
	for p in _pickables:
		if p.available and not p.picked:
			out.append(p.id)
	return out

## Pick up the NEAREST currently-available object (the natural "use what you're looking at" choice
## when several are in range). Hides it from the live scene (= picked up) and records it in the
## inventory. Returns the picked id, or "" if nothing was in range. `player_pos` breaks the
## nearest-tie; refresh(player_pos) must have run this frame so `available` is current.
func use_nearest(player_pos: Vector3) -> String:
	var best: Pickable = null
	var best_d := INF
	for p in _pickables:
		if not p.available or p.picked or not is_instance_valid(p.node):
			continue
		var d := player_pos.distance_squared_to(p.node.global_position)
		if d < best_d:
			best_d = d
			best = p
	if best == null:
		return ""
	best.picked = true
	best.available = false
	if is_instance_valid(best.node):
		best.node.visible = false      # picked up: removed from the world (non-destructive — the node lives)
	_inventory.append(best.id)
	return best.id

func inventory() -> Array:
	return _inventory.duplicate()

func pickable_count() -> int:
	return _pickables.size()

# --- live wiring (real window + input; skipped/handled by the test directly) -------------------

func set_player(player: Node3D) -> void:
	_player = player

func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	refresh(_player.global_position)
	# "E" = use / pick up the nearest in-range object. Edge-triggered (only on the press transition)
	# so holding E picks up one object, not one per frame. (Headless tests call use_nearest() directly.)
	var e_down := Input.is_key_pressed(KEY_E)
	if e_down and not _e_was_down and not available_ids().is_empty():
		var picked := use_nearest(_player.global_position)
		if picked != "":
			print("[pickup] picked up '%s' (inventory: %d)" % [picked, _inventory.size()])
	_e_was_down = e_down

var _e_was_down := false
