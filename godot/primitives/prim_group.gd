class_name PrimGroup
extends Primitive
## Groups several scene_node descriptors into ONE scene_node (a transform-only parent whose
## children are the inputs) — as DATA. This is the recursive composition building block: a
## building is a Group of walls + furniture; a city is a Group of buildings; and because a
## Group's children can themselves be Groups, scenes nest "all the way down". Place the whole
## group by wiring Group -> Transform (one function per node — the Group itself is identity).
##
## A Group emits only renderer-neutral data, so a grouped multi-object scene is exactly as
## portable as a single object: it exports to one glTF node sub-tree and round-trips the same.
##
## params.count = number of child input ports (in_0 .. in_{count-1}); default 2.
## params.name  = optional group node name.
## Null / non-scene_node inputs are skipped, so a partly-wired Group still composes.

func _init() -> void:
	prim_type = "Group"

func _count() -> int:
	return maxi(int(params.get("count", 2)), 0)

func input_ports() -> Array:
	var ports := []
	for i in _count():
		ports.append({ "name": "in_%d" % i, "type": "scene_node" })
	return ports

func output_ports() -> Array:
	return [{ "name": "node", "type": "scene_node" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var children := []
	for i in _count():
		var child = inputs.get("in_%d" % i)
		if typeof(child) == TYPE_DICTIONARY and child.has("translation"):
			children.append(child)
	return { "node": {
		"name": String(params.get("name", "group")),
		"translation": [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": null,
		"children": children
	} }
