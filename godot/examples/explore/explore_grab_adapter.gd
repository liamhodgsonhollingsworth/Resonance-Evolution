class_name ExploreGrabAdapter
extends Node3D
## THIN ADAPTER over the sandbox GRAB + INVENTORY public API (walkabout/pickup_interactor.gd +
## walkabout/build_hud.gd). The explorer demo (explore_scene_demo.gd) talks ONLY to this adapter,
## never to PickupInteractor / BuildHud directly, so if the peer lane changes that interface the
## fix is ONE file (this one), not a scatter across the demo.
##
## WHY AN ADAPTER (dispatch note): the grab/inventory feature is OWNED by another lane. This lane
## imports it READ-ONLY and treats it as a PUBLIC API. The methods it depends on today are:
##   <PickupInteractor>.new()                   — construct
##   .set_player(body)                          — the body whose position gates proximity pickup
##   .set_world_root(root)                      — where placed objects are re-added (place-down)
##   .register(id, node, radius, descriptor)    — make a live Node3D a walk-up-pickable
##   .inventory_changed  (signal)               — fires on pickup / place / cycle
##   .held_total() / .pickable_count()          — inventory + registration counts (for tests/logs)
##   <BuildHud>.new().bind(interactor)          — the on-screen inventory panel
## Every one of those is exercised by the peer's own headless tests, so they are stable contract.
## If any signature shifts, only the wrappers below change.
##
## We load both peer scripts by PATH (preload/load), never by their `class_name` global. That is the
## repo-wide portability rule (mistake #046 + runtime/asset_library.gd): outside the editor a
## class_name resolves only via the gitignored .godot class cache, so a path load is what makes this
## adapter boot with or without a warmed cache. Deliberately NO behaviour of its own: it forwards.

const PICKUP_SCRIPT := preload("res://walkabout/pickup_interactor.gd")
const HUD_SCRIPT := preload("res://walkabout/build_hud.gd")

var _interactor: Node3D = null          # a PickupInteractor (typed loosely; loaded by path)
var _hud: CanvasLayer = null            # a BuildHud

signal inventory_changed                # re-emitted from the interactor so the demo can react

## Build the interactor + HUD and attach them under `parent`. `player` is the body whose position
## gates proximity; `world_root` is where placed objects rejoin the tree. Returns true on success.
func setup(parent: Node, player: Node3D, world_root: Node3D) -> bool:
	_interactor = PICKUP_SCRIPT.new() as Node3D
	if _interactor == null:
		push_warning("ExploreGrabAdapter: could not construct PickupInteractor")
		return false
	_interactor.name = "PickupInteractor"
	parent.add_child(_interactor)
	if _interactor.has_method("set_player"):
		_interactor.set_player(player)
	if _interactor.has_method("set_world_root"):
		_interactor.set_world_root(world_root)
	# Re-broadcast the peer's inventory_changed so the demo does not depend on the peer's signal name.
	if _interactor.has_signal("inventory_changed"):
		_interactor.inventory_changed.connect(func(): inventory_changed.emit())

	var hud_node: Object = HUD_SCRIPT.new()
	if hud_node is CanvasLayer:
		_hud = hud_node
		_hud.name = "BuildHud"
		parent.add_child(_hud)
		if _hud.has_method("bind"):
			_hud.bind(_interactor)
	return true

## Register a live scene Node3D as a walk-up-pickable of the given inventory TYPE. `descriptor` is
## the renderer-neutral scene_node DATA the node was built from (its mesh identity = inventory type,
## and what place-down re-renders). Radius is how close the player must be to grab it.
func register_pickable(id: String, node: Node3D, radius: float, descriptor: Dictionary) -> void:
	if _interactor == null or not _interactor.has_method("register"):
		return
	_interactor.register(id, node, radius, descriptor)

## Total objects currently held across all inventory types (0 before any pickup).
func held_total() -> int:
	if _interactor != null and _interactor.has_method("held_total"):
		return int(_interactor.held_total())
	return 0

## How many pickables are registered (for logs / the headless test).
func pickable_count() -> int:
	if _interactor != null and _interactor.has_method("pickable_count"):
		return int(_interactor.pickable_count())
	return 0

## The underlying interactor (escape hatch for a headless test that drives refresh()/use_nearest()
## directly, exactly as the peer's own test does). Prefer the wrappers above in the demo itself.
func interactor() -> Node3D:
	return _interactor
