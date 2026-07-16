extends SceneTree
## Headless test suite for tools/physical_seed_reader.gd:
##
##   godot --headless --path godot -s res://headless_physical_seed_reader_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

const HERRINGBONE_PATH := "res://assets/paver_exemplars/herringbone_2brick.json"
const RUNNING_BOND_PATH := "res://assets/paver_exemplars/running_bond_1brick.json"

func _initialize() -> void:
	var ok := true
	ok = _test_herringbone_loads_8_members() and ok
	ok = _test_herringbone_has_explicit_lattice() and ok
	ok = _test_running_bond_loads_1_member() and ok
	ok = _test_brick_dims_passed_through() and ok
	ok = _test_missing_file_returns_empty_not_crash() and ok
	ok = _test_malformed_json_returns_empty_not_crash() and ok
	ok = _test_read_dispatches_by_extension() and ok
	ok = _test_lattice_inference_from_bbox() and ok
	ok = _test_herringbone_lattice_exact_cover_no_gap_no_overlap() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _test_herringbone_loads_8_members() -> bool:
	var data := PhysicalSeedReader.read_data_json(HERRINGBONE_PATH)
	var members: Array = data.get("members", [])
	return _check("read_data_json(herringbone): loads the 8-brick verified exact-cover unit cell", members.size() == 8)


func _test_herringbone_has_explicit_lattice() -> bool:
	var data := PhysicalSeedReader.read_data_json(HERRINGBONE_PATH)
	var la: Vector2 = data.get("lattice_a", Vector2.ZERO)
	var lb: Vector2 = data.get("lattice_b", Vector2.ZERO)
	var ok := la.is_equal_approx(Vector2(0.4, 0.0)) and lb.is_equal_approx(Vector2(0.0, 0.4))
	return _check("read_data_json(herringbone): explicit lattice_a/lattice_b read verbatim from the JSON", ok)


func _test_running_bond_loads_1_member() -> bool:
	var data := PhysicalSeedReader.read_data_json(RUNNING_BOND_PATH)
	var members: Array = data.get("members", [])
	return _check("read_data_json(running_bond): loads the 1-brick unit cell", members.size() == 1)


func _test_brick_dims_passed_through() -> bool:
	var data := PhysicalSeedReader.read_data_json(HERRINGBONE_PATH)
	var ok := absf(float(data.get("brick_length", 0.0)) - 0.2) < 1e-6
	ok = ok and absf(float(data.get("brick_width", 0.0)) - 0.1) < 1e-6
	return _check("read_data_json: brick_length/brick_width pass through from the seed file", ok)


func _test_missing_file_returns_empty_not_crash() -> bool:
	var data := PhysicalSeedReader.read_data_json("res://assets/paver_exemplars/does_not_exist.json")
	var ok := (data.get("members", []) as Array).is_empty()
	ok = ok and (data.get("lattice_a", Vector2.ONE) as Vector2).is_equal_approx(Vector2.ZERO)
	return _check("read_data_json: missing file degrades to empty, does not crash", ok)


func _test_malformed_json_returns_empty_not_crash() -> bool:
	var tmp_path := "res://assets/paver_exemplars/_test_malformed_tmp.json"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	f.store_string("{\"not_members\": []}")
	f.close()
	var data := PhysicalSeedReader.read_data_json(tmp_path)
	var ok := (data.get("members", []) as Array).is_empty()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	return _check("read_data_json: malformed seed (no 'members' key) degrades to empty, does not crash", ok)


func _test_read_dispatches_by_extension() -> bool:
	var via_dispatch := PhysicalSeedReader.read(HERRINGBONE_PATH)
	var via_direct := PhysicalSeedReader.read_data_json(HERRINGBONE_PATH)
	var ok: bool = (via_dispatch.get("members", []) as Array).size() == (via_direct.get("members", []) as Array).size()
	return _check("read(): dispatches .json paths to read_data_json", ok)


func _test_lattice_inference_from_bbox() -> bool:
	var tmp_path := "res://assets/paver_exemplars/_test_no_lattice_tmp.json"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"members": [
			{"offset": [0.0, 0.0], "rotation_deg": 0},
			{"offset": [1.0, 0.0], "rotation_deg": 0},
			{"offset": [0.0, 2.0], "rotation_deg": 0},
		]
	}))
	f.close()
	var data := PhysicalSeedReader.read_data_json(tmp_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	var la: Vector2 = data.get("lattice_a", Vector2.ZERO)
	var lb: Vector2 = data.get("lattice_b", Vector2.ZERO)
	# bbox is [0,1] x [0,2] -> inferred lattice_a=(1,0), lattice_b=(0,2)
	var ok := la.is_equal_approx(Vector2(1.0, 0.0)) and lb.is_equal_approx(Vector2(0.0, 2.0))
	return _check("read_data_json: lattice inferred from member bounding box when absent from the seed", ok)


## The load-bearing correctness property (design doc sec4): the shipped herringbone exemplar must be
## a genuine exact-cover of its own lattice cell -- rasterize a region at fine resolution using the
## SAME tiling stamp BrickPavementGenerator itself uses (via a thin local reimplementation, since this
## is a data-shape test not a BrickPavementGenerator test) and confirm every sample point is covered
## by exactly one member's footprint (brick_length x brick_width, honoring each member's own
## rotation), matching the external verification the exemplar's own JSON "_verification" field claims.
func _test_herringbone_lattice_exact_cover_no_gap_no_overlap() -> bool:
	var data := PhysicalSeedReader.read_data_json(HERRINGBONE_PATH)
	var members: Array = data["members"]
	var la: Vector2 = data["lattice_a"]
	var lb: Vector2 = data["lattice_b"]
	var brick_length: float = data["brick_length"]
	var brick_width: float = data["brick_width"]

	var rects: Array = []
	for m in range(-8, 9):
		for n in range(-8, 9):
			var base: Vector2 = float(m) * la + float(n) * lb
			for mem in members:
				var offset: Vector2 = mem["offset"]
				var center: Vector2 = base + offset
				var rotated: bool = int(mem["rotation_deg"]) % 180 == 90
				var hx: float = (brick_width if rotated else brick_length) * 0.5
				var hz: float = (brick_length if rotated else brick_width) * 0.5
				rects.append(Rect2(center.x - hx, center.y - hz, hx * 2.0, hz * 2.0))

	# res is deliberately NOT a nice multiple of the brick dimensions (0.05/0.1/0.2) and samples are
	# offset by half a step from the region origin -- otherwise sample points land exactly ON brick
	# edges (which are all at 0.05-multiples), and a strict-inequality point-in-rect test then
	# spuriously reports "gap" at every such coincidence -- a sampling-grid-alignment artifact, not a
	# real tiling defect (this is why the standalone Python verification that derived these numbers,
	# noted in the JSON's own "_verification" field, used an offset half-step sample grid too).
	var res := 0.0137
	# Sample a small region several lattice cells IN FROM the edge of the generated (-8..8) copies --
	# a finite copy range necessarily has real edge effects near its own boundary (fewer neighbors
	# generated there), which is a test-harness artifact, not a property of the true infinite tiling;
	# sampling well inside avoids conflating the two.
	var region := Rect2(0.4, 0.4, 0.8, 0.8)
	var total := 0
	var once := 0
	var zero := 0
	var multi := 0
	var x := region.position.x + res * 0.5
	while x < region.position.x + region.size.x:
		var z := region.position.y + res * 0.5
		while z < region.position.y + region.size.y:
			total += 1
			var cnt := 0
			for r in rects:
				if r.position.x < x and x < r.position.x + r.size.x and r.position.y < z and z < r.position.y + r.size.y:
					cnt += 1
			if cnt == 0:
				zero += 1
			elif cnt == 1:
				once += 1
			else:
				multi += 1
			z += res
		x += res

	var ok := total > 0 and once == total and zero == 0 and multi == 0
	return _check("herringbone exemplar: rasterized coverage is exactly-once everywhere (%d/%d samples, %d gaps, %d overlaps)" %
		[once, total, zero, multi], ok)
