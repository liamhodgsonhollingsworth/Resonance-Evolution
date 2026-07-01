class_name PartsCatalog
extends RefCounted
## The basic-parts library helper (GZ-3D.3). Loads the renderer-neutral parts manifest
## (`godot/assets/parts/catalog.json`) and emits a `scene_node` descriptor for a part BY NAME
## in one call — so a basic building block is "one node / one call": drop a part, wire it.
##
## Everything here is pure DATA in / DATA out (no live Godot object on any wire): the emitted
## descriptor is the SAME `mesh:{source:"primitive", shape, params}` scene_node the renderer
## delegate + the glTF exporter already consume, so a catalog part is cross-renderer portable
## exactly like every other primitive scene_node — zero foundation edit.
##
## The catalog is the single source of truth for the vocabulary; the evolver / procgen / the
## Lathe read `shapes()` + `defaults_for()` from here, and `part_node()` is the emitter.

const CATALOG_PATH := "res://assets/parts/catalog.json"

# Load + parse the catalog manifest. Returns the parsed Dictionary, or {} on any failure
# (missing file / bad JSON) — callers treat {} as "no catalog", never crash.
static func load_catalog(path: String = CATALOG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

# Every part entry (Array of Dictionaries) from a catalog dict (or the default catalog if omitted).
static func parts(catalog: Dictionary = {}) -> Array:
	var cat := catalog if not catalog.is_empty() else load_catalog()
	var ps = cat.get("parts", [])
	return ps if typeof(ps) == TYPE_ARRAY else []

# The list of part NAMES available in the catalog (for discovery / node-picker UIs).
static func shapes(catalog: Dictionary = {}) -> Array:
	var out := []
	for part in parts(catalog):
		if typeof(part) == TYPE_DICTIONARY and (part as Dictionary).has("name"):
			out.append(String((part as Dictionary)["name"]))
	return out

# Find a part entry by its `name` OR any of its `aliases`. Returns {} if unknown.
static func find_part(name: String, catalog: Dictionary = {}) -> Dictionary:
	for part in parts(catalog):
		if typeof(part) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = part
		if String(d.get("name", "")) == name:
			return d
		var aliases = d.get("aliases", [])
		if typeof(aliases) == TYPE_ARRAY and aliases.has(name):
			return d
	return {}

# The default param values for a part, flattened { param: default } from the catalog's
# { param: {default, min, max, ...} } schema. {} if the part is unknown.
static func defaults_for(name: String, catalog: Dictionary = {}) -> Dictionary:
	var part := find_part(name, catalog)
	if part.is_empty():
		return {}
	var out := {}
	var schema = part.get("params", {})
	if typeof(schema) == TYPE_DICTIONARY:
		for key in (schema as Dictionary).keys():
			var spec = (schema as Dictionary)[key]
			if typeof(spec) == TYPE_DICTIONARY and (spec as Dictionary).has("default"):
				out[key] = (spec as Dictionary)["default"]
	return out

# The `shape` string the renderer builds for a part (its canonical `shape`, resolving an alias
# lookup back to the entry's own shape). "" if unknown.
static func shape_for(name: String, catalog: Dictionary = {}) -> String:
	var part := find_part(name, catalog)
	return String(part.get("shape", "")) if not part.is_empty() else ""

## Emit a renderer-neutral `scene_node` descriptor for a catalog part BY NAME — the one-call/one-node
## helper. `overrides` merges on top of the catalog defaults (only the keys you tune need be passed);
## `pos` (optional [x,y,z]) places it. Unknown part name → {} (caller decides how to surface it).
static func part_node(name: String, overrides: Dictionary = {}, pos: Array = [0.0, 0.0, 0.0], catalog: Dictionary = {}) -> Dictionary:
	var part := find_part(name, catalog)
	if part.is_empty():
		return {}
	var shape := String(part.get("shape", name))
	var params := defaults_for(name, catalog)
	for k in overrides.keys():
		params[k] = overrides[k]
	return {
		"name": name,
		"translation": [float(pos[0]), float(pos[1]), float(pos[2])] if pos.size() >= 3 else [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": { "source": "primitive", "shape": shape, "params": params },
		"children": []
	}
