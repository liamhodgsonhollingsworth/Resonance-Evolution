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

# The single live Camera3D this delegate builds/drives from a `view` descriptor, kept across renders
# so a hotload RE-WIRES it (not rebuilds). Null until a View descriptor is first seen. ADDITIVE: when
# no View is present this stays null and any pre-existing hardcoded camera remains the active one.
var _view_camera: Camera3D = null

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

# --- camera / view (the renderer-neutral `view` descriptor -> a live Camera3D) ---------------
# These are PURELY ADDITIVE: render() (above) is untouched and only ever builds scene_node trees,
# so a graph with no View node renders exactly as before and the host's hardcoded fallback camera
# stays active. apply_view() runs alongside render() only when a View descriptor is present.

## A `view` descriptor is one glTF-2.0 camera, in glTF canonical space (+Y up, meters, radians):
##   { type:"perspective", yfov:<rad>, znear:<f>, zfar:<f>,
##     transform:{ translation:[x,y,z], rotation:[x,y,z,w], scale:[x,y,z] },
##     look_at:[x,y,z]?, target_node:"<id>"? }
static func is_view(v) -> bool:
	return typeof(v) == TYPE_DICTIONARY and String((v as Dictionary).get("type", "")) == "perspective" \
		and (v as Dictionary).has("transform")

## Find the FIRST view descriptor in an evaluate() output (scanning every node's output ports).
## Returns the descriptor Dictionary, or {} if the arrangement carries no View. Stable scan order
## (sorted node ids) so a multi-View arrangement picks deterministically.
static func find_view(eval_output: Dictionary) -> Dictionary:
	var ids: Array = eval_output.keys()
	ids.sort()
	for node_id in ids:
		var outs = eval_output[node_id]
		if typeof(outs) != TYPE_DICTIONARY:
			continue
		for port in outs.keys():
			if is_view(outs[port]):
				return outs[port]
	return {}

## Build / update the live Camera3D from one evaluate() output, ALONGSIDE render(). When the output
## contains a View descriptor, the delegate's own Camera3D is built (once) + driven from it and made
## current; on hotload the SAME camera instance is re-driven (never rebuilt). When NO View is present
## the previously-built ViewCamera (if any) is RELEASED — freed and the ref nulled — so the host's
## hardcoded fallback camera resumes being `current`. This makes the "additive no-op" contract hold
## for the had-then-removed hotload case too (View-present -> hotload-to-no-View must restore the
## fallback), not merely the never-had-a-View case. Returns the active view Camera3D, or null if no
## View descriptor was found. `scene_roots` (optional) is the same roots list render() used; it lets
## `target_node` aim resolve against the placed scene. Pass the GodotSceneRenderer's own parent as
## `mount` if you want the camera outside the (possibly transformed) renderer subtree; defaults to this.
func apply_view(eval_output: Dictionary, arrangement: Dictionary, mount: Node = null) -> Camera3D:
	var view := find_view(eval_output)
	if view.is_empty():
		# Had-then-removed: release the ViewCamera so it stops being `current`. queue_free() leaves it
		# `current` until it's actually freed (next frame), which would orphan the viewport's camera for
		# a frame; clearing `current` first hands control straight back to the host's fallback camera.
		if _view_camera != null and is_instance_valid(_view_camera):
			_view_camera.current = false
			_view_camera.queue_free()
		_view_camera = null
		return null
	if _view_camera == null or not is_instance_valid(_view_camera):
		_view_camera = Camera3D.new()
		_view_camera.name = "ViewCamera"
		var parent: Node = mount if mount != null else self
		parent.add_child(_view_camera)
	drive_camera(_view_camera, view, select_roots(eval_output, arrangement))
	_view_camera.current = true
	return _view_camera

## Drive a Camera3D from a `view` descriptor (static so the headless test + any host can reuse it).
## Placement: transform.translation + transform.rotation (glTF quaternion). Aim override: look_at
## (explicit point) or target_node (resolved against scene_roots; falls back to world origin).
## Projection: yfov (radians) -> Camera3D.fov (degrees, the VERTICAL fov since keep_aspect = KEEP_HEIGHT,
## Godot's default), znear/zfar -> near/far.
static func drive_camera(cam: Camera3D, view: Dictionary, scene_roots: Array = []) -> void:
	var trs: Dictionary = view.get("transform", {})
	var pos := _vec3(trs.get("translation", [0, 0, 0]), Vector3.ZERO)
	# Aim override (look_at wins over target_node; both override the quaternion). look_at == camera
	# position is degenerate, so fall back to the authored rotation then.
	var aim = _resolve_aim(view, scene_roots)
	if aim != null and not (aim as Vector3).is_equal_approx(pos):
		# Compute the look-at basis MANUALLY (not Camera3D.look_at, which requires the node to be in
		# the tree) so this works off-tree too — e.g. the glTF exporter's off-tree scene. Godot cameras
		# look down -Z, matching Basis.looking_at's convention.
		cam.transform = Transform3D(Basis.looking_at(aim - pos, Vector3.UP), pos)
	else:
		cam.transform = Transform3D(_quat(trs.get("rotation", [0, 0, 0, 1])), pos)
	if view.has("yfov"):
		cam.fov = rad_to_deg(float(view.get("yfov")))
	if view.has("znear"):
		cam.near = float(view.get("znear"))
	if view.has("zfar"):
		cam.far = float(view.get("zfar"))

# Resolve the aim point: explicit look_at, else the world-origin translation of the named target
# node found in scene_roots, else null (no aim -> authored rotation is used). Returns Vector3 | null.
static func _resolve_aim(view: Dictionary, scene_roots: Array):
	if view.has("look_at") and view.get("look_at") != null:
		return _vec3(view.get("look_at"), Vector3.ZERO)
	# Read into a var and treat a present-but-null target_node as absent: the {} default of get()
	# does NOT apply to a key that is present with value null, and String(null) is a runtime error.
	var tv = view.get("target_node")
	var target := "" if tv == null else String(tv)
	if target == "":
		return null
	for r in scene_roots:
		if typeof(r) == TYPE_DICTIONARY and String((r as Dictionary).get("node_id", "")) == target:
			var d = (r as Dictionary).get("desc")
			if typeof(d) == TYPE_DICTIONARY:
				return _vec3((d as Dictionary).get("translation", [0, 0, 0]), Vector3.ZERO)
	# Named but unresolved (e.g. the target's not a terminal root): aim at the world origin so a
	# target-by-id view still frames the scene center instead of silently falling back to rotation.
	return Vector3.ZERO

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
	# Re-apply character morph (blend-shape) weights every render so live tuning of morph_weights on a
	# reused instance (same glb → instance kept) updates the face without a geometry reload.
	var msh = desc.get("mesh")
	if typeof(msh) == TYPE_DICTIONARY and String((msh as Dictionary).get("source", "")) == "character":
		_apply_morph_weights(inst["node"], (msh as Dictionary).get("morph_weights", {}))
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
		elif src == "character":
			# A CHARACTER is a resolved FLAME-style genome whose geometry lives in a generated GLB
			# (with morph targets) at mesh.glb — produced by tools/character_resolver.py. It is an
			# ADDITIVE sibling of "glb": the genome (mesh.genome) + per-expression morph_weights ride
			# as DATA (provenance, evolvable), and the geometry loads through the SAME glb path, so a
			# character is just another renderer-neutral scene_node — zero floor/primitive edits.
			var cpath := String(mesh.get("glb", mesh.get("path", "")))
			if cpath != "":
				var cloaded := _load_glb(cpath)
				if cloaded != null:
					_apply_morph_weights(cloaded, mesh.get("morph_weights", {}))
					node.add_child(cloaded)
		elif src == "primitive":
			# Engine-built primitive mesh (the basic-parts vocabulary): a portable, ASSET-FREE
			# mesh source. It exports to glTF and loads in three.js the same as any other mesh, so
			# an evolver-/procgen-/parts-catalog-produced primitive scene stays cross-renderer
			# portable. `params` (optional) tunes the shape's dimensions — DATA only, no code path.
			var mi := MeshInstance3D.new()
			mi.name = "mesh"
			mi.mesh = _primitive_mesh(String(mesh.get("shape", "box")), mesh.get("params", {}))
			node.add_child(mi)
	return node

## Drive the imported character's blend-shape (morph) weights from the descriptor's morph_weights
## ({ "expr0": w, ... } | { "0": w, ... }). The character GLB names blend shapes "morph0..N" (Godot's
## default for unnamed glTF targets); we map by INDEX so an "exprN"/"N"/raw-index key all land. This is
## what makes a face "tunable live" — the same morph_weights field the evolver mutates (research §2).
static func _apply_morph_weights(root: Node, weights) -> void:
	if typeof(weights) != TYPE_DICTIONARY or (weights as Dictionary).is_empty():
		return
	for child in _find_mesh_instances(root):
		var m: Mesh = child.mesh
		if m == null:
			continue
		for i in m.get_blend_shape_count():
			var w = _weight_for_index(weights, i)
			if w != null:
				child.set_blend_shape_value(i, float(w))

static func _weight_for_index(weights: Dictionary, i: int) -> Variant:
	for key in ["expr%d" % i, str(i), "morph%d" % i]:
		if weights.has(key):
			return weights[key]
	return null

static func _find_mesh_instances(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_mesh_instances(c))
	return out

# --- the basic-parts primitive vocabulary -------------------------------------------------
# One renderer-neutral shape name (+ optional params dict) → a concrete Godot Mesh. Every shape
# here builds a non-empty mesh, exports to a spec-valid GLB (via GltfExporter → append_from_scene),
# and loads in three.js — so a `mesh:{source:"primitive", shape, params}` scene_node is portable
# across renderers with NO foundation edit (the shape name + params are the only new DATA). The
# authoritative, discoverable list of shapes + their params/defaults lives in
# `godot/assets/parts/catalog.json` (renderer-neutral) — this builder is its Godot realization.
#
# Built-in PrimitiveMesh subclasses cover box/sphere/cylinder/cone/torus/plane/capsule/prism;
# the rest (wedge, pyramid, tube, stairs, arch) are built as ArrayMesh from surface arrays here.
static func _primitive_mesh(shape: String, params = {}) -> Mesh:
	var p: Dictionary = params if typeof(params) == TYPE_DICTIONARY else {}
	match shape:
		"box", "cube":
			var m := BoxMesh.new()
			m.size = Vector3(_pf(p, "width", 1.0), _pf(p, "height", 1.0), _pf(p, "depth", 1.0))
			return m
		"sphere":
			var m := SphereMesh.new()
			var r := _pf(p, "radius", 0.5)
			m.radius = r
			m.height = _pf(p, "height", r * 2.0)
			m.radial_segments = int(_pf(p, "radial_segments", 32))
			m.rings = int(_pf(p, "rings", 16))
			return m
		"cylinder":
			var m := CylinderMesh.new()
			var r := _pf(p, "radius", 0.5)
			m.top_radius = _pf(p, "top_radius", r)
			m.bottom_radius = _pf(p, "bottom_radius", r)
			m.height = _pf(p, "height", 1.0)
			m.radial_segments = int(_pf(p, "radial_segments", 32))
			return m
		"cone":
			# A cylinder with a zero top radius = a cone (its own catalog entry for discoverability).
			var m := CylinderMesh.new()
			m.top_radius = _pf(p, "top_radius", 0.0)
			m.bottom_radius = _pf(p, "radius", 0.5)
			m.height = _pf(p, "height", 1.0)
			m.radial_segments = int(_pf(p, "radial_segments", 32))
			return m
		"tube", "ring", "pipe":
			# Hollow cylinder (annular tube): built here from surface arrays (no built-in).
			return _tube_mesh(
				_pf(p, "outer_radius", 0.5), _pf(p, "inner_radius", 0.3),
				_pf(p, "height", 1.0), int(_pf(p, "radial_segments", 32)))
		"torus":
			var m := TorusMesh.new()
			m.inner_radius = _pf(p, "inner_radius", 0.3)
			m.outer_radius = _pf(p, "outer_radius", 0.5)
			m.rings = int(_pf(p, "rings", 32))
			m.ring_segments = int(_pf(p, "ring_segments", 16))
			return m
		"plane", "quad":
			var m := PlaneMesh.new()
			m.size = Vector2(_pf(p, "width", 1.0), _pf(p, "depth", 1.0))
			m.subdivide_width = int(_pf(p, "subdivide_width", 0))
			m.subdivide_depth = int(_pf(p, "subdivide_depth", 0))
			return m
		"capsule":
			var m := CapsuleMesh.new()
			m.radius = _pf(p, "radius", 0.3)
			m.height = _pf(p, "height", 1.0)
			m.radial_segments = int(_pf(p, "radial_segments", 32))
			m.rings = int(_pf(p, "rings", 8))
			return m
		"prism":
			# Triangular prism (built-in PrismMesh): a ramp/wedge whose slope is set by left_to_right.
			var m := PrismMesh.new()
			m.size = Vector3(_pf(p, "width", 1.0), _pf(p, "height", 1.0), _pf(p, "depth", 1.0))
			m.left_to_right = _pf(p, "left_to_right", 0.5)
			return m
		"wedge", "ramp":
			# Right-angle ramp (triangular cross-section, flat back) — the canonical building block
			# for slopes/roofs. Built from surface arrays so the hypotenuse + both caps are solid.
			return _wedge_mesh(_pf(p, "width", 1.0), _pf(p, "height", 1.0), _pf(p, "depth", 1.0))
		"pyramid":
			# Square-based pyramid (4 triangular faces + a base).
			return _pyramid_mesh(
				_pf(p, "width", 1.0), _pf(p, "height", 1.0), _pf(p, "depth", 1.0))
		"stairs":
			# A composite building block: N equal steps rising +Y and advancing +Z. One ArrayMesh.
			return _stairs_mesh(
				_pf(p, "width", 1.0), _pf(p, "total_height", 1.0),
				_pf(p, "total_depth", 1.0), int(_pf(p, "steps", 4)))
		"arch":
			# A composite building block: two piers + a semicircular arch of voussoirs over the gap.
			return _arch_mesh(
				_pf(p, "width", 2.0), _pf(p, "height", 2.0), _pf(p, "depth", 0.5),
				_pf(p, "thickness", 0.4), int(_pf(p, "segments", 12)))
		_:
			return BoxMesh.new()

# Read a float param with a fallback (tolerates int/float/string-number DATA).
static func _pf(p: Dictionary, key: String, fallback: float) -> float:
	if p.has(key) and p[key] != null:
		return float(p[key])
	return fallback

# --- ArrayMesh builders for the shapes with no built-in PrimitiveMesh equivalent -----------
# Each returns a solid, closed, correctly-wound (CCW front-face) ArrayMesh centered sensibly on
# the origin. They emit POSITION + NORMAL (no UVs) — enough for a spec-valid GLB that renders +
# validates + loads in three.js, matching the asset-free intent of the primitive seam.

# A single flat triangle (a, b, c) with a computed face normal.
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length() > 0.0:
		n = n.normalized()
	st.set_normal(n); st.add_vertex(a)
	st.set_normal(n); st.add_vertex(b)
	st.set_normal(n); st.add_vertex(c)

# A planar quad (a,b,c,d, CCW) as two triangles sharing one face normal.
static func _quad_face(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)

# Hollow cylinder (annular tube): outer + inner walls, and top/bottom annular rings. Centered on Y.
static func _tube_mesh(outer_r: float, inner_r: float, height: float, seg: int) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	seg = max(3, seg)
	if inner_r >= outer_r:
		inner_r = outer_r * 0.6
	var hy := height * 0.5
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var co0 := Vector3(cos(a0) * outer_r, 0, sin(a0) * outer_r)
		var co1 := Vector3(cos(a1) * outer_r, 0, sin(a1) * outer_r)
		var ci0 := Vector3(cos(a0) * inner_r, 0, sin(a0) * inner_r)
		var ci1 := Vector3(cos(a1) * inner_r, 0, sin(a1) * inner_r)
		var up := Vector3(0, hy, 0)
		var dn := Vector3(0, -hy, 0)
		_quad_face(st, co0 + dn, co1 + dn, co1 + up, co0 + up) # outer wall (faces out)
		_quad_face(st, ci1 + dn, ci0 + dn, ci0 + up, ci1 + up) # inner wall (faces in)
		_quad_face(st, co0 + up, co1 + up, ci1 + up, ci0 + up) # top ring
		_quad_face(st, ci0 + dn, ci1 + dn, co1 + dn, co0 + dn) # bottom ring
	return st.commit()

# Right-angle wedge: a box footprint (width×depth) whose top slopes from full height at -Z to 0 at +Z.
static func _wedge_mesh(width: float, height: float, depth: float) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := width * 0.5
	var hd := depth * 0.5
	var b0 := Vector3(-hw, 0, -hd) # back-left base
	var b1 := Vector3(hw, 0, -hd)  # back-right base
	var f0 := Vector3(-hw, 0, hd)  # front-left base
	var f1 := Vector3(hw, 0, hd)   # front-right base
	var t0 := Vector3(-hw, height, -hd) # back-left top
	var t1 := Vector3(hw, height, -hd)  # back-right top
	_quad_face(st, f0, f1, b1, b0)   # bottom (faces -Y)
	_quad_face(st, b0, b1, t1, t0)   # back vertical wall (faces -Z)
	_quad_face(st, f0, t0, t1, f1)   # sloped top (hypotenuse)
	_tri(st, f0, b0, t0)             # left triangular cap
	_tri(st, f1, t1, b1)             # right triangular cap
	return st.commit()

# Square-based pyramid: 4 triangular sides meeting at an apex over a rectangular base.
static func _pyramid_mesh(width: float, height: float, depth: float) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := width * 0.5
	var hd := depth * 0.5
	var a := Vector3(-hw, 0, -hd)
	var b := Vector3(hw, 0, -hd)
	var c := Vector3(hw, 0, hd)
	var d := Vector3(-hw, 0, hd)
	var apex := Vector3(0, height, 0)
	_quad_face(st, a, d, c, b)  # base (faces -Y)
	_tri(st, d, a, apex)        # -X side
	_tri(st, c, d, apex)        # +Z side
	_tri(st, b, c, apex)        # +X side
	_tri(st, a, b, apex)        # -Z side
	return st.commit()

# Staircase: `steps` equal boxes rising +Y and advancing +Z, filling total_height × total_depth.
static func _stairs_mesh(width: float, total_height: float, total_depth: float, steps: int) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	steps = max(1, steps)
	var hw := width * 0.5
	var rise := total_height / float(steps)
	var run := total_depth / float(steps)
	for i in steps:
		var y1 := rise * float(i + 1)
		var z0 := run * float(i)
		_append_box(st, Vector3(-hw, 0.0, z0), Vector3(hw, y1, total_depth))
	return st.commit()

# Semicircular arch: two rectangular piers + a ring of trapezoidal voussoirs bridging the span.
static func _arch_mesh(width: float, height: float, depth: float, thickness: float, segments: int) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	segments = max(3, segments)
	var hd := depth * 0.5
	var radius := width * 0.5
	var pier_h: float = max(0.0, height - radius)
	var pier_w := thickness
	if pier_h > 0.0:
		_append_box(st, Vector3(-radius, 0, -hd), Vector3(-radius + pier_w, pier_h, hd))
		_append_box(st, Vector3(radius - pier_w, 0, -hd), Vector3(radius, pier_h, hd))
	for i in segments:
		var a0 := PI - PI * float(i) / float(segments)
		var a1 := PI - PI * float(i + 1) / float(segments)
		var inner0 := Vector3(cos(a0) * radius, pier_h + sin(a0) * radius, 0)
		var inner1 := Vector3(cos(a1) * radius, pier_h + sin(a1) * radius, 0)
		var outer0 := Vector3(cos(a0) * (radius + thickness), pier_h + sin(a0) * (radius + thickness), 0)
		var outer1 := Vector3(cos(a1) * (radius + thickness), pier_h + sin(a1) * (radius + thickness), 0)
		var f := Vector3(0, 0, hd)
		var bk := Vector3(0, 0, -hd)
		_quad_face(st, inner0 + f, inner1 + f, outer1 + f, outer0 + f)  # front face
		_quad_face(st, outer0 + bk, outer1 + bk, inner1 + bk, inner0 + bk) # back face
		_quad_face(st, inner0 + bk, inner1 + bk, inner1 + f, inner0 + f) # intrados (inner)
		_quad_face(st, outer0 + f, outer1 + f, outer1 + bk, outer0 + bk) # extrados (outer)
	return st.commit()

# Append an axis-aligned box spanning [mn, mx] (6 outward-facing quads) to a SurfaceTool.
static func _append_box(st: SurfaceTool, mn: Vector3, mx: Vector3) -> void:
	var a := Vector3(mn.x, mn.y, mn.z)
	var b := Vector3(mx.x, mn.y, mn.z)
	var c := Vector3(mx.x, mn.y, mx.z)
	var d := Vector3(mn.x, mn.y, mx.z)
	var e := Vector3(mn.x, mx.y, mn.z)
	var f := Vector3(mx.x, mx.y, mn.z)
	var g := Vector3(mx.x, mx.y, mx.z)
	var h := Vector3(mn.x, mx.y, mx.z)
	_quad_face(st, a, d, c, b)  # bottom (-Y)
	_quad_face(st, e, f, g, h)  # top (+Y)
	_quad_face(st, a, b, f, e)  # -Z
	_quad_face(st, d, h, g, c)  # +Z
	_quad_face(st, a, e, h, d)  # -X
	_quad_face(st, b, c, g, f)  # +X

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
	if src == "character":
		# Key on the GLB path so a hotload that only changes morph_weights (live tuning) RE-WIRES the
		# same instance instead of reloading the geometry; the weights are applied per-render via
		# apply_trs's sibling _apply_morph_weights. (Re-resolving the genome writes a NEW glb path.)
		return "character:" + String(mesh.get("glb", mesh.get("path", "")))
	if src == "primitive":
		# Key on shape AND params so a hotload that tunes a dimension (e.g. cone radius) RE-WIRES a
		# fresh mesh instead of reusing the old geometry. Params are a small dict of scalars → a
		# stable JSON string is a cheap, order-independent (Godot sorts dict keys) identity.
		return "prim:" + String(mesh.get("shape", "")) + ":" + JSON.stringify(mesh.get("params", {}))
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
