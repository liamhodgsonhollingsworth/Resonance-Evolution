class_name PrimTextureApply
extends Primitive
## The TEXTURE-APPLY node — the node-based live-texturing driver (Liam 2026-07-02: untextured
## building blocks "textured LIVE using tools in the game engine", with texture application
## driven by a NODE-BASED system). It emits a renderer-NEUTRAL `material_op` as plain DATA:
##
##   { "op": "set_material", "cell": [x, y, z], "material": { ... } }
##
## where `material` is the same descriptor the sandbox's _apply_material seam consumes:
##   { "albedo": [r,g,b], "albedo_texture": "res://path.png",
##     "procedural": { "kind": "checker"|"gradient"|"noise"|"bricks", ... },   # see TextureSynth
##     "roughness": f, "metallic": f }
##
## The node performs NO rendering and touches NO scene node — it is pure dataflow, so it is
## portable and hot-reloadable via the LiveHost arrangement pattern: edit the arrangement's
## params (a colour, a kind, a target cell) on disk and the running graph re-emits the op with
## no restart. The APPLICATION is the consumer's job: the sandbox consumes exactly this shape
## through its params-JSON `material_ops` list (godot/examples/sandbox_creative.gd), and the
## Godot pixel synthesis lives in the renderer delegate (renderers/texture_synth.gd).
##
## Inputs (both optional — wire them OR set params; wired values win):
##   spec : the material descriptor Dictionary
##   cell : the target grid cell [x, y, z]
## Params fallbacks: params.material (Dictionary), params.cell (Array).
## Output:
##   material_op : the op Dictionary above ({} when no material is configured — a bare node
##                 emits an inert op rather than crashing the graph).

func _init() -> void:
	prim_type = "TextureApply"

func input_ports() -> Array:
	return [
		{ "name": "spec", "type": "any" },
		{ "name": "cell", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "material_op", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var material = inputs.get("spec")
	if typeof(material) != TYPE_DICTIONARY:
		material = params.get("material", {})
	if typeof(material) != TYPE_DICTIONARY or (material as Dictionary).is_empty():
		return { "material_op": {} }
	var cell = inputs.get("cell")
	if typeof(cell) != TYPE_ARRAY:
		cell = params.get("cell", [0, 0, 0])
	var cell_arr: Array = []
	if typeof(cell) == TYPE_ARRAY and (cell as Array).size() >= 3:
		cell_arr = [int(cell[0]), int(cell[1]), int(cell[2])]
	else:
		cell_arr = [0, 0, 0]
	return { "material_op": {
		"op": "set_material",
		"cell": cell_arr,
		"material": (material as Dictionary).duplicate(true),
	} }
