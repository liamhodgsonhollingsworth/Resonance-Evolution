extends SceneTree
## Headless verification of the SDF math module (renderers/sdf.gd) + the SdfEdit primitive in the REAL
## GraphRuntime:
##
##   godot --headless --path godot -s res://headless_sdf_edit_test.gd
##
## SdfEdit is a pure DATA primitive (emits an edit-list descriptor; it does NOT render), so evaluating
## it inside a live GraphRuntime IS the real path. Proves: analytic SDF VALUES vs hand-computed oracles
## (sphere/box/round-box/torus/cylinder/plane); the polynomial smooth-min contract (k=0 == hard min,
## k>0 <= hard min, symmetric); CSG add/subtract/intersect over an edit list; that a CHAIN of SdfEdit
## nodes accumulates an ordered edit-list through the runtime (the DATA the sculpt slice consumes); the
## D ideal (edit a shape param hot-loads as a diff, same instance re-evaluates); the C ideal (sever the
## chain wire -> the downstream edit no longer sees the upstream one). Mirrors headless_chip_test.gd.

const EPS := 1e-5

func _initialize() -> void:
	var ok := true
	ok = _primitive_distances() and ok
	ok = _smooth_min_contract() and ok
	ok = _csg_ops() and ok
	ok = _edit_distance_transform() and ok
	ok = _chain_emits_ordered_editlist() and ok
	ok = _field_distance_composition() and ok
	ok = _diff_hotload_shape_param() and ok
	ok = _connection_isolated_failure() and ok
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# -- Analytic primitive distances vs hand-computed oracles -----------------------------------------
func _primitive_distances() -> bool:
	var ok := true
	# Sphere r=1: at origin => -1 (inside), at (2,0,0) => 1 (outside), on surface (1,0,0) => 0.
	ok = _near("sphere inside", SDF.sd_sphere(Vector3.ZERO, 1.0), -1.0) and ok
	ok = _near("sphere outside", SDF.sd_sphere(Vector3(2, 0, 0), 1.0), 1.0) and ok
	ok = _near("sphere surface", SDF.sd_sphere(Vector3(1, 0, 0), 1.0), 0.0) and ok
	# Box half-extent (1,1,1): at (2,0,0) => 1 (1 unit past the +x face); center => -1 (nearest face).
	ok = _near("box outside face", SDF.sd_box(Vector3(2, 0, 0), Vector3(1, 1, 1)), 1.0) and ok
	ok = _near("box center", SDF.sd_box(Vector3.ZERO, Vector3(1, 1, 1)), -1.0) and ok
	# Box outside corner (2,2,0): q=(1,1,-1), outside=length(1,1,0)=sqrt(2).
	ok = _near("box outside corner", SDF.sd_box(Vector3(2, 2, 0), Vector3(1, 1, 1)), sqrt(2.0)) and ok
	# Round box = box - rad; corner radius 0.25 at the +x face point (2,0,0): 1 - 0.25 = 0.75.
	ok = _near("round box", SDF.sd_round_box(Vector3(2, 0, 0), Vector3(1, 1, 1), 0.25), 0.75) and ok
	# Torus major=2 minor=0.5 in XZ: point (2,0,0) is on the ring center => distance = -minor = -0.5.
	ok = _near("torus ring center", SDF.sd_torus(Vector3(2, 0, 0), Vector2(2.0, 0.5)), -0.5) and ok
	# Torus point (3,0,0): ring-plane dist to (2) = 1, tube dist = 1 - 0.5 = 0.5.
	ok = _near("torus outside tube", SDF.sd_torus(Vector3(3, 0, 0), Vector2(2.0, 0.5)), 0.5) and ok
	# Capped cylinder r=1 h=1 along Y: at (2,0,0) => 1 (radial); at (0,2,0) => 1 (past +y cap).
	ok = _near("cylinder radial", SDF.sd_capped_cylinder(Vector3(2, 0, 0), 1.0, 1.0), 1.0) and ok
	ok = _near("cylinder cap", SDF.sd_capped_cylinder(Vector3(0, 2, 0), 1.0, 1.0), 1.0) and ok
	# Plane normal +y offset 0: point (0,3,0) => 3; point (0,-2,0) => -2.
	ok = _near("plane above", SDF.sd_plane(Vector3(0, 3, 0), Vector3(0, 1, 0), 0.0), 3.0) and ok
	ok = _near("plane below", SDF.sd_plane(Vector3(0, -2, 0), Vector3(0, 1, 0), 0.0), -2.0) and ok
	return ok

# -- Polynomial smooth-min contract: k=0 == hard, k>0 rounds and stays <= hard min, symmetric -------
func _smooth_min_contract() -> bool:
	var ok := true
	var d1 := 0.4
	var d2 := 0.6
	ok = _near("smin k=0 == hard min", SDF.smooth_union(d1, d2, 0.0), minf(d1, d2)) and ok
	var s := SDF.smooth_union(d1, d2, 0.3)
	ok = _check("smin k>0 <= hard min (rounds inward)", s <= minf(d1, d2) + EPS) and ok
	# Symmetry: smin(a,b,k) == smin(b,a,k).
	ok = _near("smin symmetric", SDF.smooth_union(d1, d2, 0.3), SDF.smooth_union(d2, d1, 0.3)) and ok
	# Far apart (|d1-d2| >> k): smin approaches the hard min (blend inactive).
	ok = _near("smin far apart approaches hard min", SDF.smooth_union(0.0, 5.0, 0.2), 0.0, 1e-3) and ok
	# Smooth subtract with k=0 equals the hard subtract.
	ok = _near("smooth subtract k=0 == hard", SDF.smooth_subtract(0.5, 0.3, 0.0), maxf(0.5, -0.3)) and ok
	# Smooth intersect with k=0 equals the hard intersect.
	ok = _near("smooth intersect k=0 == hard", SDF.smooth_intersect(0.5, 0.3, 0.0), maxf(0.5, 0.3)) and ok
	return ok

# -- Hard CSG operators ----------------------------------------------------------------------------
func _csg_ops() -> bool:
	var ok := true
	ok = _near("union = min", SDF.op_union(0.2, -0.3), -0.3) and ok
	ok = _near("subtract = max(d1,-d2)", SDF.op_subtract(0.2, -0.3), 0.3) and ok
	ok = _near("intersect = max", SDF.op_intersect(0.2, -0.3), 0.2) and ok
	return ok

# -- edit_distance applies the transform (translation + uniform scale) before the analytic form ----
func _edit_distance_transform() -> bool:
	var ok := true
	# A sphere r=1 translated to (5,0,0): distance at (5,0,0) => -1 (its center), at origin => 4.
	var edit := { "shape": "sphere", "params": { "radius": 1.0 }, "transform": { "position": [5, 0, 0], "scale": 1.0 } }
	ok = _near("edit translate: at center => -r", SDF.edit_distance(edit, Vector3(5, 0, 0)), -1.0) and ok
	ok = _near("edit translate: at origin => 4", SDF.edit_distance(edit, Vector3.ZERO), 4.0) and ok
	# A sphere r=1 scaled x2: surface at radius 2 => distance 0 at (2,0,0), -2 at center.
	var scaled := { "shape": "sphere", "params": { "radius": 1.0 }, "transform": { "position": [0, 0, 0], "scale": 2.0 } }
	ok = _near("edit scale x2: surface at r*scale", SDF.edit_distance(scaled, Vector3(2, 0, 0)), 0.0) and ok
	ok = _near("edit scale x2: center => -r*scale", SDF.edit_distance(scaled, Vector3.ZERO), -2.0) and ok
	return ok

# -- A CHAIN of SdfEdit nodes accumulates an ORDERED edit-list through the real runtime -------------
func _chain_emits_ordered_editlist() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	# e1 (sphere, add) -> e2 (box, subtract, consumes e1.edits) : e2 emits [sphere, box].
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "e1", "type": "SdfEdit", "params": { "shape": "sphere", "op": "add", "params": { "radius": 1.0 } } },
			{ "id": "e2", "type": "SdfEdit", "params": { "shape": "box", "op": "subtract", "blend": 0.1, "params": { "half_extents": [0.5, 0.5, 0.5] } } },
		],
		"wires": [
			{ "from": "e1", "out": "edits", "to": "e2", "in": "edits" },
		],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var e1_list = out.get("e1", {}).get("edits")
	var e2_list = out.get("e2", {}).get("edits")
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("chain: e1 emits 1 edit", e1_list is Array and e1_list.size() == 1) and ok
	ok = _check("chain: e2 emits 2 edits (ordered, e1 first)", e2_list is Array and e2_list.size() == 2) and ok
	if e2_list is Array and e2_list.size() == 2:
		ok = _check("chain: order is [sphere(add), box(subtract)]",
			e2_list[0].get("shape") == "sphere" and e2_list[0].get("op") == "add"
			and e2_list[1].get("shape") == "box" and e2_list[1].get("op") == "subtract") and ok
		ok = _check("chain: format tag stamped", e2_list[1].get("format") == SDF.EDIT_FORMAT) and ok
	return ok

# -- field_distance composes the emitted edit-list into one distance field -------------------------
func _field_distance_composition() -> bool:
	var ok := true
	# Two spheres r=1 at (-1.5,0,0) and (1.5,0,0), hard union. At the origin, both are 0.5 away => 0.5.
	var edits := [
		{ "shape": "sphere", "op": "add", "blend": 0.0, "params": { "radius": 1.0 }, "transform": { "position": [-1.5, 0, 0], "scale": 1.0 } },
		{ "shape": "sphere", "op": "add", "blend": 0.0, "params": { "radius": 1.0 }, "transform": { "position": [1.5, 0, 0], "scale": 1.0 } },
	]
	ok = _near("field union: min of two spheres at origin", SDF.field_distance(edits, Vector3.ZERO), 0.5) and ok
	# Subtract: a big sphere r=2 with a smaller sphere r=1 carved at origin. At origin the carve wins:
	# max(outer=-2, -(inner=-1)) = max(-2, 1) = 1 (carved => outside).
	var carve := [
		{ "shape": "sphere", "op": "add", "blend": 0.0, "params": { "radius": 2.0 }, "transform": { "position": [0, 0, 0], "scale": 1.0 } },
		{ "shape": "sphere", "op": "subtract", "blend": 0.0, "params": { "radius": 1.0 }, "transform": { "position": [0, 0, 0], "scale": 1.0 } },
	]
	ok = _near("field subtract: carved center is outside (+1)", SDF.field_distance(carve, Vector3.ZERO), 1.0) and ok
	# Empty list is "far everywhere".
	ok = _check("field empty list => far", SDF.field_distance([], Vector3.ZERO) > 1e6) and ok
	# A single edit reproduces its own edit_distance (first edit seeds the field).
	var one := [{ "shape": "sphere", "op": "add", "blend": 0.0, "params": { "radius": 1.0 }, "transform": { "position": [0, 0, 0], "scale": 1.0 } }]
	ok = _near("field single edit == its edit_distance", SDF.field_distance(one, Vector3(2, 0, 0)), 1.0) and ok
	return ok

# -- D ideal: edit a shape param hot-loads as a diff; the SAME SdfEdit instance re-evaluates --------
func _diff_hotload_shape_param() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "e", "type": "SdfEdit", "params": { "shape": "sphere", "op": "add", "params": { "radius": 1.0 } } },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)
	var out1 := rt.evaluate()
	var r1 = out1.get("e", {}).get("edits")[0].get("params").get("radius")
	var inst1: int = rt.nodes.get("e").get_instance_id()
	# Hot-load: change radius to 3 as a diff (params updated in place, instance kept).
	var arr2: Dictionary = arr.duplicate(true)
	arr2["nodes"][0]["params"]["params"]["radius"] = 3.0
	rt.load_arrangement(arr2)
	var out2 := rt.evaluate()
	var r2 = out2.get("e", {}).get("edits")[0].get("params").get("radius")
	var inst2: int = rt.nodes.get("e").get_instance_id()
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("D: hotload radius 1 => 3", r1 == 1.0 and r2 == 3.0) and ok
	ok = _check("D: same SdfEdit instance across hotload (diff, not rebuild)", inst1 != 0 and inst1 == inst2) and ok
	return ok

# -- C ideal: sever the chain wire -> downstream edit no longer accumulates the upstream one --------
func _connection_isolated_failure() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "e1", "type": "SdfEdit", "params": { "shape": "sphere", "op": "add", "params": { "radius": 1.0 } } },
			{ "id": "e2", "type": "SdfEdit", "params": { "shape": "box", "op": "add", "params": { "half_extents": [1, 1, 1] } } },
		],
		"wires": [
			{ "from": "e1", "out": "edits", "to": "e2", "in": "edits" },
		],
	}
	rt.load_arrangement(arr)
	var before := rt.evaluate()
	var e2_before = before.get("e2", {}).get("edits").size()  # 2 (sphere + box)
	var e1_before = before.get("e1", {}).get("edits").size()  # 1 (unchanged either way)
	# Sever the chain wire: e2 now only emits its own edit (1); e1 is untouched (still 1).
	var cut: Dictionary = arr.duplicate(true)
	cut["wires"] = []
	rt.load_arrangement(cut)
	var after := rt.evaluate()
	var e2_after = after.get("e2", {}).get("edits").size()  # 1 (just the box)
	var e1_after = after.get("e1", {}).get("edits").size()  # 1 (unaffected)
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("C: severed chain wire drops exactly the upstream edit (2=>1)", e2_before == 2 and e2_after == 1) and ok
	ok = _check("C: upstream e1 unaffected by the severed wire", e1_before == 1 and e1_after == 1) and ok
	return ok

# -- helpers ---------------------------------------------------------------------------------------
func _near(label: String, got: float, want: float, tol := EPS) -> bool:
	var cond := absf(got - want) <= tol
	print(("PASS " if cond else "FAIL ") + label + "  (got %f want %f)" % [got, want])
	return cond

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
