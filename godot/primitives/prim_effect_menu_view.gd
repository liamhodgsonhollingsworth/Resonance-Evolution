class_name PrimEffectMenuView
extends Primitive
## The EFFECTS-GALLERY MENU as a pure VIEW (visi-sonor light-show Slice 2B, item 7). It reads the
## prim_effect_registry's DATA (registry + ids on wires) and emits a renderer-neutral MENU DESCRIPTOR —
## one tile per registered effect (id + thumbnail + defaults) plus a `view` descriptor tagging the layout.
## It only SELECTS / PREVIEWS; it does NOT own the effects (those are wired in the graph as ordinary prims).
##
## THE "backend independent of UI so a 3D equivalent can exist" REQUIREMENT (item 7) made concrete:
## layout = "2d_grid" (now) or "3d_panel" (later) yields an IDENTICAL tile backend — same ids, same
## defaults, same thumbnails — and differs ONLY in the emitted view descriptor's `layout` tag + camera.
## The 3D equivalent is therefore a swappable RENDERER over the same DATA, not a second menu. A renderer
## delegate draws the tiles as a 2D grid of cards OR a 3D panel of preview quads from the SAME descriptor.
##
## It REUSES the existing view-descriptor shape: for layout=3d_panel it embeds a PrimView-produced glTF
## camera descriptor (composition, not a rebuilt view engine — R ideal) so a 3D renderer places a camera
## the same way every other scene view does. For layout=2d_grid the view carries the grid geometry
## (columns / cell size) a 2D canvas renderer reads. Everything is plain DATA on wires (T ideal).
##
## params:
##   layout    "2d_grid" (default) | "3d_panel" — the ONLY thing that changes the emitted view; the tile
##             backend is identical across layouts (the item-7 backend-independence assertion).
##   columns   grid columns for 2d_grid (default 4). Ignored by 3d_panel.
##   cell      [w,h] tile cell size in px for 2d_grid (default [160,120]).
##   position/yfov/…  OPTIONAL camera params forwarded to the embedded PrimView for 3d_panel framing.
##
## inputs:
##   registry  the { effect_id -> registration } dict from prim_effect_registry (absent => zero tiles).
##   ids       OPTIONAL sorted id list from the registry (used for stable tile ORDER; falls back to the
##             registry's own keys, sorted, when unwired — so a bare wiring still enumerates every effect).
##
## outputs:
##   tiles     an ordered Array of tile descriptors: { id, thumbnail, defaults, type } — the selectable
##             / previewable menu items (plain DATA — T ideal).
##   view      the renderer-neutral view descriptor for this layout ({ layout, ... } + a glTF camera for
##             3d_panel), so a 2D or 3D renderer draws the SAME tiles its own way.
##   count     the number of tiles (convenience scalar).

const DEFAULT_COLUMNS := 4
const DEFAULT_CELL := [160.0, 120.0]

func _init() -> void:
	prim_type = "EffectMenuView"

func input_ports() -> Array:
	return [
		{ "name": "registry", "type": "any" },
		{ "name": "ids", "type": "any" },
	]

func output_ports() -> Array:
	return [
		{ "name": "tiles", "type": "any" },
		{ "name": "view", "type": "view" },
		{ "name": "count", "type": "number" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var registry = inputs.get("registry")
	if typeof(registry) != TYPE_DICTIONARY:
		registry = {}   # absent/malformed registry -> zero tiles (declared no-op, C ideal)

	# Tile ORDER: the wired `ids` list if present (the registry's stable sorted enumeration), else the
	# registry's own keys sorted — so a bare wiring (only `registry` connected) still enumerates all.
	var order := _resolve_order(inputs.get("ids"), registry)

	var tiles: Array = []
	for eid in order:
		if not (registry as Dictionary).has(eid):
			continue   # an id with no registration is skipped, never a crash (C ideal)
		var reg: Dictionary = (registry as Dictionary)[eid]
		tiles.append({
			"id": String(eid),
			"type": String(reg.get("type", "")),          # the subgraph factory the menu instantiates on select
			"thumbnail": reg.get("thumbnail", ""),         # DATA path, not a live texture (renderer resolves it)
			"defaults": (reg.get("defaults", {}) as Dictionary).duplicate(true) if reg.get("defaults") is Dictionary else {},
		})

	var layout := str(params.get("layout", "2d_grid"))
	return {
		"tiles": tiles,
		"view": _view_for(layout, tiles.size()),
		"count": tiles.size(),
	}

# --- helpers ---------------------------------------------------------------------------------------

## The tile order: prefer the wired `ids` array (registry's stable enumeration), else sort the registry's
## own keys. Always returns a defined Array (C ideal).
func _resolve_order(ids_in, registry) -> Array:
	if ids_in is Array and not (ids_in as Array).is_empty():
		var out: Array = []
		for x in ids_in:
			out.append(String(x))
		return out
	var keys: Array = (registry as Dictionary).keys() if registry is Dictionary else []
	keys.sort()
	return keys

## The renderer-neutral VIEW descriptor for this layout. 2d_grid carries grid geometry a 2D canvas reads;
## 3d_panel embeds a glTF camera descriptor from PrimView (REUSE — R ideal) so a 3D renderer frames the
## panel like any other scene view. The `layout` tag is the ONE field that distinguishes the two — the
## tile backend above is identical, satisfying item-7's "backend independent of UI".
func _view_for(layout: String, tile_count: int) -> Dictionary:
	if layout == "3d_panel":
		# Compose PrimView for the glTF camera (never rebuild a view engine). Forward any camera params.
		var pv: PrimView = PrimView.new()
		pv.params = {
			"position": params.get("position", PrimView.DEFAULT_POSITION),
			"yfov": params.get("yfov", PrimView.DEFAULT_YFOV_DEG),
		}
		if params.has("look_at"):
			pv.params["look_at"] = params.get("look_at")
		var cam: Dictionary = pv.evaluate({}).get("view", {})
		pv.free()
		return {
			"layout": "3d_panel",
			"count": tile_count,
			"camera": cam,   # the embedded glTF-2.0 camera descriptor a 3D renderer uses to place a Camera3D
		}
	# Default 2d_grid: geometry a 2D canvas renderer lays the tile cards out with.
	var columns := int(params.get("columns", DEFAULT_COLUMNS))
	if columns < 1:
		columns = 1
	var cell := _v2(params.get("cell", DEFAULT_CELL), DEFAULT_CELL)
	var rows := int(ceil(float(tile_count) / float(columns))) if tile_count > 0 else 0
	return {
		"layout": "2d_grid",
		"count": tile_count,
		"columns": columns,
		"cell": cell,
		"rows": rows,
	}

## Coerce a possibly-malformed [w,h] param to a 2-array of floats (C ideal — never crashes on bad data).
func _v2(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 2:
		return [float(a[0]), float(a[1])]
	return [float(fallback[0]), float(fallback[1])]

## Impure: the tile set depends on the wired registry (which the registry node mutates), not just params.
func is_cacheable() -> bool:
	return false
