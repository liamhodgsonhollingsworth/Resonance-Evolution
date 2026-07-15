extends SceneTree
## Headless test suite for renderers/scatter_composer.gd (Wave 1 item 1.1):
##
##   godot --headless --path godot -s res://test_scatter_composer.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	ok = _test_determinism() and ok
	ok = _test_no_overlap() and ok
	ok = _test_uniform_field_produces_points() and ok
	ok = _test_zero_field_produces_nothing() and ok
	ok = _test_half_field_biases_density() and ok
	ok = _test_call_target_stamped() and ok
	ok = _test_custom_to_transform_used() and ok
	ok = _test_different_seeds_differ() and ok
	ok = _test_sample_dicts_matches_sample() and ok
	ok = _test_max_points_cap_respected() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _test_determinism() -> bool:
	var a := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, Callable(), 42, "tree")
	var b := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, Callable(), 42, "tree")
	if a.size() != b.size():
		return _check("determinism: same seed -> same count", false)
	var all_match := true
	for i in a.size():
		if a[i].point != b[i].point or a[i].transform != b[i].transform:
			all_match = false
			break
	return _check("determinism: same seed -> identical points (%d points)" % a.size(), all_match)


func _test_no_overlap() -> bool:
	var min_dist := 1.5
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(30, 30), min_dist, Callable(), 7, "rock")
	var violated := false
	for i in points.size():
		for j in range(i + 1, points.size()):
			if points[i].point.distance_to(points[j].point) < min_dist - 0.0001:
				violated = true
				break
		if violated:
			break
	return _check("no-overlap: all %d points >= min_dist apart" % points.size(), not violated)


func _test_uniform_field_produces_points() -> bool:
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(50, 50), 2.0, Callable(), 1, "grass")
	# Loose sanity bound on Poisson-disk packing density for min_dist=2 over
	# a 50x50 domain: expect somewhere in the low hundreds, never near-zero
	# and never absurdly over the theoretical max packing.
	return _check("uniform field: point count in plausible range (%d)" % points.size(),
		points.size() > 50 and points.size() < 700)


func _test_zero_field_produces_nothing() -> bool:
	var zero_field := func(_p: Vector2) -> float:
		return 0.0
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, zero_field, 3, "nothing")
	return _check("zero field: emits no points", points.is_empty())


func _test_half_field_biases_density() -> bool:
	# Field is 1.0 for x < 10 (left half), 0.0 for x >= 10 (right half) of a
	# [0,20]x[0,20] domain. Expect points concentrated in the left half.
	var half_field := func(p: Vector2) -> float:
		return 1.0 if p.x < 10.0 else 0.0
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, half_field, 5, "bush")
	var left := 0
	var right := 0
	for pl in points:
		if pl.point.x < 10.0:
			left += 1
		else:
			right += 1
	return _check("half field: density biased to weighted half (left=%d, right=%d)" % [left, right],
		left > 0 and right == 0)


func _test_call_target_stamped() -> bool:
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(10, 10), 1.0, Callable(), 9, "pot_style_a")
	var all_stamped := true
	for pl in points:
		if pl.call_target != "pot_style_a" or pl.seed != 9:
			all_stamped = false
			break
	return _check("call_target + seed stamped on every placement (%d points)" % points.size(), all_stamped)


func _test_custom_to_transform_used() -> bool:
	var to_xform := func(p: Vector2, _rng: RandomNumberGenerator) -> Transform3D:
		return Transform3D(Basis.IDENTITY, Vector3(p.x, 42.0, p.y))
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(10, 10), 2.0, Callable(), 11, "x", to_xform)
	var all_elevated := points.size() > 0
	for pl in points:
		if absf(pl.transform.origin.y - 42.0) > 0.0001:
			all_elevated = false
			break
	return _check("custom to_transform: y=42 applied to every placement (%d points)" % points.size(),
		all_elevated)


func _test_different_seeds_differ() -> bool:
	var a := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, Callable(), 1, "x")
	var b := ScatterComposer.sample(Vector2.ZERO, Vector2(20, 20), 1.0, Callable(), 2, "x")
	var same := a.size() == b.size()
	if same:
		for i in a.size():
			if a[i].point != b[i].point:
				same = false
				break
	return _check("different seeds produce different point sets", not same)


func _test_sample_dicts_matches_sample() -> bool:
	var placements := ScatterComposer.sample(Vector2.ZERO, Vector2(10, 10), 1.5, Callable(), 21, "y")
	var dicts := ScatterComposer.sample_dicts(Vector2.ZERO, Vector2(10, 10), 1.5, Callable(), 21, "y")
	var same_shape := placements.size() == dicts.size()
	if same_shape and placements.size() > 0:
		same_shape = dicts[0]["call_target"] == placements[0].call_target \
			and dicts[0]["seed"] == placements[0].seed \
			and dicts[0]["point"] == placements[0].point
	return _check("sample_dicts matches sample (%d entries)" % dicts.size(), same_shape)


func _test_max_points_cap_respected() -> bool:
	var points := ScatterComposer.sample(Vector2.ZERO, Vector2(100, 100), 0.5, Callable(), 4, "cap", Callable(), 30, 25)
	return _check("max_points cap respected (%d <= 25)" % points.size(), points.size() <= 25)
