class_name GodotSceneRenderer
extends Node3D
## The Godot RENDERER DELEGATE — the ONLY Godot-coupled piece of the 3D path.
##
## It consumes a GraphRuntime.evaluate() output (pure renderer-neutral DATA) and builds /
## updates a live Node3D tree from the `scene_node` descriptors it finds. The arrangement
## values stay engine-agnostic (glTF-aligned dicts, no Godot objects on any wire); ALL the
## glTF->Godot coordinate + Node3D logic lives behind this seam, so the SAME data can drive a
## different renderer (a three.js delegate, the glTF exporter, ...) unchanged.
##
## A `scene_node` descriptor is one glTF node sub-tree, in glTF canonical space (+Y up,
## meters, radians):
##   { "name": String, "translation": [x,y,z], "rotation": [x,y,z,w] (unit quaternion),
##     "scale": [x,y,z], "mesh": { "source": "glb", "path": String } | null,
##     "children": [ scene_node, ... ] }

# Live instances kept across renders so a hotload RE-WIRES (not rebuilds): key -> {node, mesh_key}.
var _instances: Dictionary = {}

## Build / update the live scene from one evaluate() output. Unchanged instances are reused
## (a live model survives re-wiring of everything around it); vanished ones are pruned.
func render(eval_output: Dictionary, arrangement: Dictionary) -> void:
	var roots := select_roots(eval_output, arrangement)
	var seen := {}
	for r in roots:
		# Key by the PRODUCING (node_id, port) so a live instance survives sibling churn
		# (adding/removing/reordering other nodes), instead of being rebuilt on an index shift.
		_sync(r["desc"], self, "r:%s/%s" % [r["node_id"], r["port"]], seen)
	for key in _instances.keys():
		if not seen.has(key):
			_instances[key]["node"].queue_free()
			_instances.erase(key)

## Roots = scene_node values on output ports of nodes that are NOT a wire source (terminal),
## so a Model wired into a Transform renders once (via the Transform), not twice. Falls back
## to every scene_node output if no terminal node produced one. Each entry carries its
## producing identity { "node_id", "port", "desc" } so render() keys live instances STABLY.
## (Terminal detection is node-granular for now; a dangling sibling output on a multi-output
## node is a known, currently-unreachable edge — see PROGRESS.md.)
static func select_roots(eval_output: Dictionary, arrangement: Dictionary) -> Array:
	var sources := {}
	for w in arrangement.get("wires", []):
		sources[String(w.get("from"))] = true
	var roots := []
	for node_id in eval_output.keys():
		if sources.has(node_id):
			continue
		_gather_scene_nodes(node_id, eval_output[node_id], roots)
	if roots.is_empty():
		for node_id in eval_output.keys():
			_gather_scene_nodes(node_id, eval_output[node_id], roots)
	return roots

static func _gather_scene_nodes(node_id, outs, into: Array) -> void:
	if typeof(outs) != TYPE_DICTIONARY:
		return
	for port in outs.keys():
		if is_scene_node(outs[port]):
			into.append({ "node_id": String(node_id), "port": String(port), "desc": outs[port] })

static func is_scene_node(v) -> bool:
	return typeof(v) == TYPE_DICTIONARY and v.has("translation") and v.has("rotation") and v.has("scale")

func _sync(desc: Dictionary, parent: Node, key: String, seen: Dictionary) -> void:
	seen[key] = true
	var want_key := mesh_key(desc.get("mesh"))
	var inst = _instances.get(key)
	if inst == null or String(inst["mesh_key"]) != want_key:
		if inst != null:
			inst["node"].queue_free()
		var node := build_node(desc)
		parent.add_child(node)
		inst = { "node": node, "mesh_key": want_key }
		_instances[key] = inst
	apply_trs(inst["node"], desc)
	var kids: Array = desc.get("children", [])
	for j in kids.size():
		_sync(kids[j], inst["node"], key + ".%d" % j, seen)

# --- static builders: shared by the live renderer AND the glTF exporter, so what is shown
# --- on screen and what is exported provably come from the same tree walk. -----------------

## Build an off-tree Node3D subtree for a list of root descriptors under `parent` (fresh, no
## instance reuse) — used by GltfExporter and the round-trip oracle's reference tree.
static func build_static_tree(roots: Array, parent: Node) -> void:
	for i in roots.size():
		_build_subtree(roots[i], parent, "r%d" % i)

static func _build_subtree(desc: Dictionary, parent: Node, key: String) -> void:
	var node := build_node(desc)
	parent.add_child(node)
	apply_trs(node, desc)
	var kids: Array = desc.get("children", [])
	for j in kids.size():
		_build_subtree(kids[j], node, key + ".%d" % j)

## One Node3D for a descriptor, with its GLB geometry loaded as a child. No GLB caching: the
## instance reuse in render() already prevents reloads during hotload of surrounding nodes.
static func build_node(desc: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = _safe_name(desc.get("name", ""), "node")
	var mesh = desc.get("mesh")
	if typeof(mesh) == TYPE_DICTIONARY:
		var src := String(mesh.get("source", ""))
		if src == "glb":
			var path := String(mesh.get("path", ""))
			if path != "":
				var loaded := _load_glb(path)
				if loaded != null:
					node.add_child(loaded)
		elif src == "primitive":
			# Engine-built primitive mesh (box/sphere/cylinder): a portable, ASSET-FREE mesh
			# source. It exports to glTF and loads in three.js the same as any other mesh, so an
			# evolver-produced primitive scene stays cross-renderer portable.
			var mi := MeshInstance3D.new()
			mi.name = "mesh"
			mi.mesh = _primitive_mesh(String(mesh.get("shape", "box")))
			node.add_child(mi)
	return node

static func _primitive_mesh(shape: String) -> Mesh:
	match shape:
		"sphere":
			return SphereMesh.new()
		"cylinder":
			return CylinderMesh.new()
		_:
			return BoxMesh.new()

# NOTE (portability boundary): `path` is a res:// / user:// / absolute pointer in GODOT's
# namespace. The descriptor itself stays portable, but a non-Godot delegate (e.g. three.js)
# must resolve this path itself (or be handed the GLB bytes). Keep that resolution per-delegate.
static func _load_glb(path: String) -> Node:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		push_warning("GodotSceneRenderer: failed to load GLB '%s'" % path)
		return null
	return doc.generate_scene(st)

## THE coordinate boundary: neutral glTF TRS -> Godot Transform3D. translation/scale match
## between glTF and Godot; rotation is carried as a quaternion. (The forward-axis divergence,
## +Z glTF vs -Z Godot, is deferred — it only matters once forward-facing semantics are added,
## and the conversion for that belongs HERE, at this single boundary.)
static func apply_trs(node: Node3D, desc: Dictionary) -> void:
	var t := _vec3(desc.get("translation", [0, 0, 0]), Vector3.ZERO)
	var s := _vec3(desc.get("scale", [1, 1, 1]), Vector3.ONE)
	var q := _quat(desc.get("rotation", [0, 0, 0, 1]))
	node.transform = Transform3D(Basis(q).scaled(s), t)

static func mesh_key(mesh) -> String:
	if typeof(mesh) != TYPE_DICTIONARY:
		return ""
	var src := String(mesh.get("source", ""))
	if src == "glb":
		return "glb:" + String(mesh.get("path", ""))
	if src == "primitive":
		return "prim:" + String(mesh.get("shape", ""))
	return JSON.stringify(mesh)

static func _vec3(a, fallback: Vector3) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func _quat(a) -> Quaternion:
	if a is Array and (a as Array).size() >= 4:
		return Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3]))
	return Quaternion.IDENTITY

static func _safe_name(raw, fallback: String) -> String:
	var s := String(raw).strip_edges()
	if s == "":
		s = fallback
	return s.validate_node_name()
