extends RefCounted
## WORLD ↔ ARRANGEMENT — the sandbox's live edit-model expressed as a `resonance.arrangement/v1`
## graph (Liam 2026-07-06: EVERY scene/room is a node arrangement that diff-hotloads).
##
## The creative sandbox edits a live model of BLOCKS (voxel cells) + OBJECTS (placed GLB assets and
## free-placed primitive blocks) + NOTES. This module is the ONE seam that turns that model into the
## SAME JSON `{nodes, wires}` the GraphRuntime interprets and the GodotSceneRenderer builds — and back
## again losslessly. So the sandbox persists + hotloads through the exact `load_arrangement -> evaluate
## -> render` path lsystem_scene and the aperture room (aperture_room_shell.json) already run on.
##
## GEOMETRY VOCABULARY (the canonical, non-forked geometry arrangement — Const / Model / Transform /
## Group, plus Environment / Light where a scene carries them). We emit ONLY this vocabulary so the
## arrangement renders identically through GraphRuntime; the behavior/logic/input node families being
## added elsewhere are additive and untouched here.
##   • a voxel BLOCK          -> Const(primitive scene_node) -> Transform(cell->world) -> Group
##   • an ASSET object        -> Model(glb path)             -> Transform(pos/rot/scale) -> Group
##   • a free-placed BLOCK obj-> Const(primitive scene_node) -> Transform(pos/rot/scale) -> Group
## Every node's TERMINAL Transform feeds the one `world` Group, whose output is the whole scene.
##
## LOSSLESS ROUND-TRIP: the geometry maps to the shared vocabulary; the sandbox-specific edit metadata
## that has no geometry meaning (the block cell, the asset id, behaviors, the wand's pitch/roll axes,
## the block object flag, materials, grid_size, notes) rides as EXTRA keys the schema already permits
## ("additionalProperties": true) — on each node under a "_sandbox" block, and on the arrangement root.
## A pure geometry reader ignores them; the sandbox reads them back to reconstruct an identical world.
##
## No class_name (mistake #046): consumers preload() this file by path.

const FORMAT := "resonance.arrangement/v1"
const GROUP_ID := "world"


## Serialize the live sandbox model into a `resonance.arrangement/v1` dictionary.
##   blocks:  Array of { cell:[x,y,z], block:<name>, shape:<mesh shape>, params:<mesh params>, material:<desc> }
##   objects: Array of the per-object edit records already produced by sandbox _serialize (id, position,
##            yaw_deg, [pitch_deg,roll_deg], scale, behaviors, and EITHER asset:<id> OR block:<name>)
##   asset_paths: { asset_id -> res:// glb path } so a Model node carries a loadable path (portable:
##            a reader resolves geometry without the sandbox's AssetLibrary).
##   block_shapes: { block_name -> { shape, params, material } } the palette's mesh vocabulary, so a
##            free-placed block object serializes to a real primitive scene_node.
## Extra (grid_size, notes, name) is carried verbatim on the arrangement root.
static func serialize(blocks: Array, objects: Array, asset_paths: Dictionary,
		block_shapes: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var nodes := []
	var wires := []
	var group_inputs := 0
	var grid_size := float(extra.get("grid_size", 1.0))

	# ── voxel BLOCKS: Const(primitive scene_node) -> Transform(cell->world) -> Group ──────────────
	for b in blocks:
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var cell = b.get("cell", [0, 0, 0])
		if typeof(cell) != TYPE_ARRAY or (cell as Array).size() < 3:
			continue
		var name := String(b.get("block", "Cube"))
		var vocab: Dictionary = block_shapes.get(name, {})
		var shape := String(b.get("shape", vocab.get("shape", "box")))
		var params = b.get("params", vocab.get("params", {}))
		var material = b.get("material", {})
		var scene_node := _primitive_scene_node(name, shape, params, material)
		var base := "blk_%d_%d_%d" % [int(cell[0]), int(cell[1]), int(cell[2])]
		var pos := _cell_to_world(cell, grid_size)
		var sandbox_meta := { "kind": "block", "cell": [int(cell[0]), int(cell[1]), int(cell[2])],
			"block": name, "material": _dup(material) }
		nodes.append({ "id": base, "type": "Const", "params": { "value": scene_node } })
		nodes.append({ "id": base + "_at", "type": "Transform",
			"params": { "position": pos }, "_sandbox": sandbox_meta })
		wires.append({ "from": base, "out": "value", "to": base + "_at", "in": "node" })
		wires.append({ "from": base + "_at", "out": "node", "to": GROUP_ID, "in": "in_%d" % group_inputs })
		group_inputs += 1

	# ── OBJECTS: asset -> Model, free-placed block -> Const; then Transform(pos/rot/scale) -> Group ─
	for o in objects:
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var oid := String(o.get("id", ""))
		if oid == "":
			continue
		var p = o.get("position", [0, 0, 0])
		if typeof(p) != TYPE_ARRAY or (p as Array).size() < 3:
			continue
		var position := [float(p[0]), float(p[1]), float(p[2])]
		var yaw := float(o.get("yaw_deg", 0.0))
		var pitch := float(o.get("pitch_deg", 0.0))
		var roll := float(o.get("roll_deg", 0.0))
		var scale := float(o.get("scale", 1.0))
		# Godot Euler is applied YXZ; the sandbox authors yaw(Y)/pitch(X)/roll(Z) — emit [pitch, yaw, roll].
		var rotation := [pitch, yaw, roll]
		var sandbox_meta := { "kind": "object", "id": oid,
			"behaviors": _dup(o.get("behaviors", [])) }
		if absf(pitch) > 1e-9:
			sandbox_meta["pitch_deg"] = pitch
		if absf(roll) > 1e-9:
			sandbox_meta["roll_deg"] = roll
		var src_id := oid
		if o.has("block") and not o.has("asset"):
			# free-placed primitive block object -> a Const primitive scene_node
			var bname := String(o["block"])
			var vocab: Dictionary = block_shapes.get(bname, {})
			var scene_node := _primitive_scene_node(bname,
				String(vocab.get("shape", "box")), vocab.get("params", {}), vocab.get("material", {}))
			sandbox_meta["kind"] = "block_object"
			sandbox_meta["block"] = bname
			nodes.append({ "id": src_id, "type": "Const", "params": { "value": scene_node } })
			wires.append({ "from": src_id, "out": "value", "to": src_id + "_at", "in": "node" })
		else:
			# asset object -> a Model that references the GLB by path (portable, self-loading)
			var asset := String(o.get("asset", ""))
			var glb := String(asset_paths.get(asset, ""))
			sandbox_meta["asset"] = asset
			nodes.append({ "id": src_id, "type": "Model",
				"params": { "path": glb, "name": asset } })
			wires.append({ "from": src_id, "out": "node", "to": src_id + "_at", "in": "node" })
		nodes.append({ "id": src_id + "_at", "type": "Transform",
			"params": { "position": position, "rotation": rotation, "scale": [scale, scale, scale] },
			"_sandbox": sandbox_meta })
		wires.append({ "from": src_id + "_at", "out": "node", "to": GROUP_ID, "in": "in_%d" % group_inputs })
		group_inputs += 1

	# ── the one world Group (all terminal Transforms feed it) ────────────────────────────────────
	nodes.append({ "id": GROUP_ID, "type": "Group",
		"params": { "count": group_inputs, "name": "sandbox_world" } })

	var arr := {
		"format": FORMAT,
		"name": String(extra.get("name", "sandbox-world")),
		"nodes": nodes,
		"wires": wires,
	}
	# sandbox-only edit metadata that has no geometry meaning rides on the root, losslessly.
	arr["grid_size"] = grid_size
	if extra.has("notes"):
		arr["notes"] = _dup(extra["notes"])
	return arr


## Deserialize a `resonance.arrangement/v1` back into the sandbox's edit-model dicts:
##   { "blocks": [...], "objects": [...], "notes": [...], "grid_size": <f> }
## — the SAME shape the sandbox's _apply_world_data() already consumes. Reads the "_sandbox" metadata
## on each Transform node; a node without it (e.g. an Environment/Light or a hand-authored geometry
## node) is skipped for the edit-model (it still renders through GraphRuntime — this only reconstructs
## the EDITABLE model). Fail-soft: anything malformed is skipped, never crashes.
static func deserialize(arrangement: Dictionary) -> Dictionary:
	var blocks := []
	var objects := []
	for n in arrangement.get("nodes", []):
		if typeof(n) != TYPE_DICTIONARY:
			continue
		if not n.has("_sandbox"):
			continue
		var meta: Dictionary = n["_sandbox"]
		var kind := String(meta.get("kind", ""))
		var tparams: Dictionary = n.get("params", {})
		if kind == "block":
			blocks.append({
				"cell": meta.get("cell", [0, 0, 0]),
				"block": String(meta.get("block", "Cube")),
				"material": _dup(meta.get("material", {})),
			})
		elif kind == "object" or kind == "block_object":
			var pos = tparams.get("position", [0, 0, 0])
			var rot = tparams.get("rotation", [0.0, 0.0, 0.0])
			var scl = tparams.get("scale", [1.0, 1.0, 1.0])
			var scale_f := 1.0
			if typeof(scl) == TYPE_ARRAY and (scl as Array).size() >= 1:
				scale_f = float(scl[0])
			elif typeof(scl) in [TYPE_FLOAT, TYPE_INT]:
				scale_f = float(scl)
			var entry := {
				"id": String(meta.get("id", "")),
				"position": [float(pos[0]), float(pos[1]), float(pos[2])] if typeof(pos) == TYPE_ARRAY and pos.size() >= 3 else [0.0, 0.0, 0.0],
				"yaw_deg": float(rot[1]) if typeof(rot) == TYPE_ARRAY and rot.size() >= 2 else 0.0,
				"scale": scale_f,
				"behaviors": _dup(meta.get("behaviors", [])),
			}
			if meta.has("pitch_deg"):
				entry["pitch_deg"] = float(meta["pitch_deg"])
			if meta.has("roll_deg"):
				entry["roll_deg"] = float(meta["roll_deg"])
			if kind == "block_object":
				entry["block"] = String(meta.get("block", "Cube"))
			else:
				entry["asset"] = String(meta.get("asset", ""))
			objects.append(entry)

	var out := { "blocks": blocks, "objects": objects }
	if arrangement.has("grid_size"):
		out["grid_size"] = float(arrangement["grid_size"])
	if arrangement.has("notes"):
		out["notes"] = _dup(arrangement["notes"])
	return out


## True when `data` is a resonance.arrangement/v1 dict (vs a legacy sandbox.world/v2 dict). Lets the
## sandbox load either shape (append-only: old saved worlds keep loading).
static func is_arrangement(data: Dictionary) -> bool:
	return String(data.get("format", "")).begins_with("resonance.arrangement/")


## Build a renderer-neutral primitive `scene_node` descriptor (the SAME shape PartsCatalog.part_node and
## the aperture room shell's Const boxes use). Carries the sandbox material descriptor as an extra key so
## the round-trip is lossless (the renderer's build_node ignores unknown keys; the sandbox reads it back).
static func _primitive_scene_node(node_name: String, shape: String, params, material) -> Dictionary:
	var sn := {
		"name": node_name,
		"translation": [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": { "source": "primitive", "shape": shape,
			"params": params if typeof(params) == TYPE_DICTIONARY else {} },
		"children": [],
	}
	if typeof(material) == TYPE_DICTIONARY and not (material as Dictionary).is_empty():
		sn["material"] = _dup(material)
	return sn


static func _cell_to_world(cell: Array, grid_size: float) -> Array:
	var g := grid_size if grid_size > 0.0 else 1.0
	return [float(cell[0]) * g, float(cell[1]) * g, float(cell[2]) * g]


static func _dup(v):
	if typeof(v) == TYPE_DICTIONARY:
		return (v as Dictionary).duplicate(true)
	if typeof(v) == TYPE_ARRAY:
		return (v as Array).duplicate(true)
	return v
