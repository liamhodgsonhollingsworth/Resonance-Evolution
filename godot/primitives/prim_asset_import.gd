class_name PrimAssetImport
extends Primitive
## Emits a renderer-NEUTRAL scene_node descriptor for a library asset REFERENCED BY MANIFEST ID —
## as DATA, never a live Godot node. It is a thin front-end over the EXISTING lazy asset manifest
## (godot/assets/manifest.json + the AssetLibrary contract entry(id)/has_asset(id)): give it a
## manifest id, it resolves the GLB path from the manifest and emits a Model-shaped scene_node the
## renderer already knows how to build (GodotSceneRenderer._build_scene_node, mesh.source="glb").
##
## THE C-IDEAL (isolated-failure) — the load-bearing reason this node exists as its OWN primitive
## rather than a bare Model node: if the referenced GLB file is ABSENT (a lighting-kit asset whose
## bytes are not yet downloaded), or the id is UNKNOWN (not in the manifest), it FALLS BACK to a
## PLACEHOLDER mesh (mesh.source="primitive": a box or cylinder the renderer builds asset-free) —
## it NEVER crashes and NEVER blocks on a network fetch. So a room arrangement referencing lighting
## fixtures is fully headless-testable and renderable the moment it is authored, and each fixture
## silently upgrades from placeholder -> real GLB when the asset lands. Same "unknown = declared
## no-op" portability posture as device_actions ("unknown op = no-op").
##
## This is renderer-neutral (gate T): the output is the SAME scene_node DATA shape PrimModel/PrimGroup
## emit, so it wires into Transform/Group/View exactly like any other model, and a non-Godot delegate
## resolves the path itself. Deliberately NO class-cache dependency at the consumer boundary — the
## renderer dispatches on the plain `mesh.source` string, so nothing here edits an existing primitive.
##
## params:
##   id               manifest asset id (e.g. "kenney_furniture__lamp_round_floor"). May be wired.
##   manifest_path    which manifest to resolve against (default res://assets/manifest.json).
##   name             optional scene_node name (default = the id).
##   placeholder_shape "box" | "cylinder" — the fallback primitive when the GLB is absent/unknown
##                     (default "box"; lamps read nicer as "cylinder"). DATA only.
##   placeholder_params optional {width,height,depth} | {radius,height} for the fallback mesh.
##
## inputs (optional — wire OR set params; wired wins, so a fixture's id is a rewireable data change):
##   id : the manifest id (overrides params.id)
##
## outputs:
##   node        the scene_node descriptor (always a valid dict — glb OR placeholder primitive)
##   placeholder bool — true if the fallback primitive was emitted (GLB absent/unknown), false if the
##               real GLB path was emitted. Lets a downstream node / test distinguish the two states.

const DEFAULT_MANIFEST := "res://assets/manifest.json"

func _init() -> void:
	prim_type = "AssetImport"

func input_ports() -> Array:
	return [{ "name": "id", "type": "any" }]

func output_ports() -> Array:
	return [
		{ "name": "node", "type": "scene_node" },
		{ "name": "placeholder", "type": "any" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	# Wired id wins over the param (str() coerce — a numeric/Variant id must not crash, mistake #049 class).
	var wired = inputs.get("id")
	var id := str(wired) if wired != null else str(params.get("id", ""))
	var node_name := String(params.get("name", id if id != "" else "asset"))
	var shape := String(params.get("placeholder_shape", "box"))

	# Resolve the GLB path from the manifest WITHOUT loading any bytes (metadata only — the cheap path).
	var glb_path := _resolve_path(id, String(params.get("manifest_path", DEFAULT_MANIFEST)))

	# The GLB is usable only if the manifest knew the id AND the file actually exists on disk. Either
	# gap -> the placeholder branch (C-ideal: absent asset = a box/cylinder, never a crash / a fetch).
	if glb_path != "" and FileAccess.file_exists(glb_path):
		return {
			"node": {
				"name": node_name,
				"translation": [0.0, 0.0, 0.0],
				"rotation": [0.0, 0.0, 0.0, 1.0],
				"scale": [1.0, 1.0, 1.0],
				"mesh": { "source": "glb", "path": glb_path },
				"children": [],
			},
			"placeholder": false,
		}

	# PLACEHOLDER FALLBACK — an engine-built asset-free primitive mesh the renderer builds with zero
	# asset dependency (the SAME mesh.source="primitive" path GodotSceneRenderer already dispatches).
	var pmesh := { "source": "primitive", "shape": shape }
	var pparams = params.get("placeholder_params")
	if typeof(pparams) == TYPE_DICTIONARY:
		pmesh["params"] = (pparams as Dictionary).duplicate(true)
	return {
		"node": {
			"name": node_name,
			"translation": [0.0, 0.0, 0.0],
			"rotation": [0.0, 0.0, 0.0, 1.0],
			"scale": [1.0, 1.0, 1.0],
			"mesh": pmesh,
			"children": [],
		},
		"placeholder": true,
	}

## Read ONLY the manifest metadata (a few KB) to map id -> GLB path. Returns "" for an unknown id or
## an unreadable manifest — both fall to the placeholder branch. No GLB bytes are touched here.
func _resolve_path(id: String, manifest_path: String) -> String:
	if id == "" or not FileAccess.file_exists(manifest_path):
		return ""
	var data = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	for a in data.get("assets", []):
		if typeof(a) == TYPE_DICTIONARY and str(a.get("id", "")) == id:
			return String(a.get("path", ""))
	return ""
