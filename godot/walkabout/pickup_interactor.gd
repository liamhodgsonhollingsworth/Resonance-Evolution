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
## PLACE-DOWN (the other half of the build loop): each pickable also carries the renderer-neutral
## `scene_node` descriptor it was rendered from (a glTF-aligned DATA dict, NOT a live node). On a
## "place" the selected inventory TYPE's descriptor is re-rendered into the world at a target point
## via `GodotSceneRenderer.build_node(desc)` — so pick-up (E) + place-down (Q) closes the loop and
## the kits become a buildable world. The placed object is a real scene Node3D again AND is
## registered back as a fresh pickable, so placed things can be picked up + moved again.
##
## Headless/test use: the per-frame work is split into pure methods (`refresh(player_pos)`,
## `available_ids()`, `use_nearest()`, `place_at(type, pos)`) that a headless test drives directly
## without a window or input device. `_process` only wires real Input + the live player Node3D.

const DEFAULT_RADIUS := 2.5   # meters: how close the player must be to interact

## One registered pickable: the live scene Node3D, its proximity Context runtime, and bookkeeping.
class Pickable:
	var id: String
	var node: Node3D                # the live renderer node (what gets hidden on pickup)
	var runtime: GraphRuntime      # a GraphRuntime holding this object's proximity Context
	var radius: float
	var type_key: String = ""      # the inventory TYPE (its mesh source) — what counts/places group by
	var descriptor: Dictionary = {} # the renderer-neutral scene_node DATA this object was built from
	var picked := false
	var available := false         # within radius this refresh?

var _pickables: Array[Pickable] = []
var _inventory: Array[String] = []     # ids picked up, in order (kept for back-compat + history)
# Inventory grouped by TYPE: type_key -> { "count": int, "descriptor": Dictionary, "name": String }.
# The descriptor is what place-down re-renders; count is how many of that type are held.
var _held: Dictionary = {}
var _held_order: Array[String] = []    # type_keys in first-seen order (stable HUD ordering)
var _selected_type: String = ""        # the active inventory type place-down will spawn
var _placed_seq := 0                   # monotonic id suffix for placed objects
var _player: Node3D = null             # set in walkabout; the body whose position gates proximity

# --- registration -----------------------------------------------------------------------------

## Register a live scene node as pickable. Builds a Context(handler="proximity") whose scope emits
## a constant "available" signal, gated by the player<->object distance. The Context lives in its
## OWN tiny GraphRuntime so each object is independent; positions are injected as external inputs.
##
## `descriptor` (optional) is the renderer-neutral scene_node DATA the live node was built from — it
## is what place-down re-renders, and its mesh identity is the inventory TYPE the object counts as.
## When omitted, a synthetic type is derived from `id` so the object is still inventory-tracked.
func register(id: String, node: Node3D, radius: float = DEFAULT_RADIUS, descriptor: Dictionary = {}) -> void:
	var p := Pickable.new()
	p.id = id
	p.node = node
	p.radius = radius
	p.descriptor = descriptor.duplicate(true) if not descriptor.is_empty() else {}
	p.type_key = _type_key_of(descriptor, id)
	p.runtime = GraphRuntime.new()
	add_child(p.runtime)
	p.runtime.load_arrangement(_proximity_arrangement(radius))
	_pickables.append(p)

## The inventory TYPE a pickable groups under: its mesh source (GLB path / primitive shape) so two
## copies of the same model stack as one inventory entry. Falls back to the registered id when the
## descriptor carries no mesh (still a stable, per-object type).
func _type_key_of(descriptor: Dictionary, id: String) -> String:
	if not descriptor.is_empty():
		var key := GodotSceneRenderer.mesh_key(descriptor.get("mesh"))
		if key != "":
			return key
	return "id:" + id

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
	_add_to_held(best)
	return best.id

## Record a picked-up object into the type-grouped inventory (count++ for its type, remembering the
## descriptor so place-down can re-render it). The first type ever held becomes the selected one.
func _add_to_held(p: Pickable) -> void:
	var t := p.type_key
	if not _held.has(t):
		_held[t] = { "count": 0, "descriptor": p.descriptor, "name": _display_name(p) }
		_held_order.append(t)
	_held[t]["count"] = int(_held[t]["count"]) + 1
	# Keep a usable descriptor even if the first registration lacked one.
	if (_held[t]["descriptor"] as Dictionary).is_empty() and not p.descriptor.is_empty():
		_held[t]["descriptor"] = p.descriptor
	if _selected_type == "":
		_selected_type = t

## A short human label for an inventory type (the descriptor's node name, else the type key tail).
func _display_name(p: Pickable) -> String:
	var nm := String(p.descriptor.get("name", "")).strip_edges()
	if nm != "":
		return nm
	# type_key looks like "glb:res://.../kenney_nature__bed.glb" — show the file stem.
	var tk := p.type_key
	if tk.begins_with("glb:"):
		return tk.get_file().get_basename()
	return tk

func inventory() -> Array:
	return _inventory.duplicate()

func pickable_count() -> int:
	return _pickables.size()

# --- inventory-by-type accessors (drive the HUD; pure, headless-testable) ----------------------

## Ordered inventory rows for the HUD: [{ "type", "name", "count", "selected" }, ...], in
## first-picked-up order, with the active type flagged.
func held_rows() -> Array:
	var rows: Array = []
	for t in _held_order:
		var e: Dictionary = _held[t]
		if int(e["count"]) <= 0:
			continue
		rows.append({ "type": t, "name": String(e["name"]),
			"count": int(e["count"]), "selected": (t == _selected_type) })
	return rows

## How many of `type_key` are currently held.
func held_count(type_key: String) -> int:
	if not _held.has(type_key):
		return 0
	return int(_held[type_key]["count"])

## Total objects held across all types.
func held_total() -> int:
	var n := 0
	for t in _held_order:
		n += int(_held[t]["count"])
	return n

func selected_type() -> String:
	return _selected_type

## Cycle the active inventory type to the next non-empty one (wraps). No-op when nothing is held.
## `dir` is +1 (next) or -1 (previous). Returns the newly-selected type ("" if none held).
func cycle_selection(dir: int = 1) -> String:
	var avail: Array = []
	for t in _held_order:
		if int(_held[t]["count"]) > 0:
			avail.append(t)
	if avail.is_empty():
		_selected_type = ""
		return ""
	var idx := avail.find(_selected_type)
	if idx < 0:
		_selected_type = String(avail[0])
		return _selected_type
	idx = (idx + dir) % avail.size()
	if idx < 0:
		idx += avail.size()
	_selected_type = String(avail[idx])
	return _selected_type

# --- place-down: the other half of the build loop ---------------------------------------------

## Where placed objects are added so they render in the live scene. Defaults to this interactor's
## parent (the walkabout root) when unset, so placed objects join the same tree as everything else.
var _world_root: Node3D = null

func set_world_root(root: Node3D) -> void:
	_world_root = root

func _resolve_world_root() -> Node3D:
	if _world_root != null and is_instance_valid(_world_root):
		return _world_root
	var p := get_parent()
	return p if p is Node3D else self

## Place ONE held object of `type_key` at world point `pos`. Re-renders the type's stored scene_node
## descriptor (renderer-neutral DATA) into a live Node3D via the renderer's static builder, drops it
## at `pos`, registers it back as a fresh pickable (so it can be re-picked/moved), and decrements the
## inventory count. Returns the new pickable id, or "" if none of that type are held / no descriptor.
func place_at(type_key: String, pos: Vector3) -> String:
	if not _held.has(type_key) or int(_held[type_key]["count"]) <= 0:
		return ""
	var desc: Dictionary = _held[type_key]["descriptor"]
	if desc.is_empty():
		return ""   # nothing to render (object had no descriptor) — can't place it
	# Build the live node from the SAME renderer-neutral data the original was rendered from, then
	# stamp the target translation into a copy of the descriptor so the placed pickable round-trips.
	var placed_desc: Dictionary = desc.duplicate(true)
	placed_desc["translation"] = [pos.x, pos.y, pos.z]
	var node: Node3D = GodotSceneRenderer.build_node(placed_desc)
	var world := _resolve_world_root()
	world.add_child(node)
	node.global_position = pos
	# Consume one from inventory.
	_held[type_key]["count"] = int(_held[type_key]["count"]) - 1
	if int(_held[type_key]["count"]) <= 0 and _selected_type == type_key:
		# Selected type just emptied: move selection to the next still-held type (or none).
		cycle_selection(1)
	# Register the placed object back as a pickable so the loop is closed (place -> pick -> place).
	var new_id := "placed_%d_%s" % [_placed_seq, type_key.get_file()]
	_placed_seq += 1
	register(new_id, node, DEFAULT_RADIUS, placed_desc)
	return new_id

## Place the currently-SELECTED type at `pos` (the Q-key path). Returns the new id or "".
func place_selected_at(pos: Vector3) -> String:
	if _selected_type == "":
		return ""
	return place_at(_selected_type, pos)

## The world point a place-down should target, given the player body + its look camera. Casts a ray
## from the camera forward into the scene; on a hit the placement is the hit point, otherwise it
## falls back to a point `fallback_dist` m in front of the player projected onto the ground plane
## (y=0). Result is snapped to a `grid` m grid in X/Z (set grid<=0 to disable) so builds line up.
## Pure-geometry fallback path is headless-safe; the raycast path needs a live PhysicsDirectSpaceState.
func place_target(player: Node3D, camera: Camera3D, fallback_dist: float = 3.0, grid: float = 1.0) -> Vector3:
	var point := _raycast_place_point(player, camera, fallback_dist)
	if grid > 0.0:
		point.x = roundf(point.x / grid) * grid
		point.z = roundf(point.z / grid) * grid
		point.y = maxf(point.y, 0.0)
	return point

func _raycast_place_point(player: Node3D, camera: Camera3D, fallback_dist: float) -> Vector3:
	# Try a real camera-forward raycast (windowed). Headless / no-physics → ground-plane fallback.
	if camera != null and is_instance_valid(camera) and camera.is_inside_tree():
		var space := camera.get_world_3d().direct_space_state if camera.get_world_3d() != null else null
		if space != null:
			var from := camera.global_position
			var to := from + (-camera.global_transform.basis.z) * 50.0
			var q := PhysicsRayQueryParameters3D.create(from, to)
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				return hit["position"]
	# Fallback: a point in front of the player, dropped onto the ground plane (y = 0).
	var fwd := -player.global_transform.basis.z
	var p := player.global_position + fwd * fallback_dist
	p.y = 0.0
	return p

# --- live wiring (real window + input; skipped/handled by the test directly) -------------------

## Emitted whenever the inventory or selection changes (pickup / place / cycle), so a HUD can
## refresh without polling. Carries nothing — the HUD re-reads held_rows() on the signal.
signal inventory_changed

func set_player(player: Node3D) -> void:
	_player = player

## The look camera used for place-down raycasts (the first Camera3D under the player). Cached lazily.
func _player_camera() -> Camera3D:
	if _player == null:
		return null
	for c in _player.get_children():
		if c is Camera3D:
			return c
	return null

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
			print("[pickup] picked up '%s' (inventory: %d, held %d)" % [picked, _inventory.size(), held_total()])
			inventory_changed.emit()
	_e_was_down = e_down

	# "Q" = place the SELECTED inventory type into the world at the aim point (camera-forward
	# raycast, ground-plane fallback, grid-snapped). Edge-triggered so one press places one object.
	var q_down := Input.is_key_pressed(KEY_Q)
	if q_down and not _q_was_down and _selected_type != "":
		var target := place_target(_player, _player_camera())
		var placed := place_selected_at(target)
		if placed != "":
			print("[place] placed '%s' at (%.1f, %.1f, %.1f) (held %d)" % [
				placed, target.x, target.y, target.z, held_total()])
			inventory_changed.emit()
	_q_was_down = q_down

	# TAB = cycle the active inventory type (what Q will place next). Edge-triggered.
	var tab_down := Input.is_key_pressed(KEY_TAB)
	if tab_down and not _tab_was_down and held_total() > 0:
		cycle_selection(1)
		inventory_changed.emit()
	_tab_was_down = tab_down

var _e_was_down := false
var _q_was_down := false
var _tab_was_down := false
