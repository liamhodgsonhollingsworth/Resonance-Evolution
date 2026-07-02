extends SceneTree
## Headless verification of the PROJECTION-SIM FOUNDATION: a projector-as-DATA primitive plus a
## simulated camera-feedback calibration loop, all node-wired (the shared substrate the
## drum-teaching / laser / projection-audio-sync arcs inherit). Deterministic, CPU-only
## (--headless has a dummy renderer: the pinhole/homography math in ProjectionMath is the
## calibration source of truth; the live SpotLight3D realization is demo cosmetics).
##
##   godot --headless --path godot --editor --quit-after 60     (once, class cache)
##   godot --headless --path godot -s res://headless_projection_test.gd
##
## Asserts:
##   (A) ProjectionMath self-tests: homography fit recovers a known warp; inverse composes to
##       identity; pixel->ray->plane->pixel round-trips; throw-ratio -> fov is sane.
##   (B) The arrangement wires up: 20 fiducials, all observed by the witness camera, and the
##       initial misalignment is REAL (mean error > 15 px).
##   (C) The feedback loop CONVERGES: error strictly decreases and lands under the 1.0 px
##       threshold within 12 damped iterations (gain 0.7); gain 1.0 one-shots to the floor
##       (planar projector->camera transport IS a homography — solved, not fudged).
##   (D) DETERMINISM: a fresh runtime reproduces the exact same error sequence.
##   (E) OBLIQUE + CURVED targets: a 35-degree plane calibrates below threshold; a cylindrical
##       screen still observes the grid and the loop cuts the error to a best-fit floor.
##   (F) Proof PNGs: before/after observed views (+ side-by-side composite) land in docs/.

const ARRANGEMENT := "res://examples/projection_sim.json"
const PNG_BEFORE := "res://docs/projection_calibration_before.png"
const PNG_AFTER := "res://docs/projection_calibration_after.png"
const PNG_PROOF := "res://docs/projection_calibration_proof.png"
const THRESHOLD := 1.0
const MAX_ITERS := 12

func _initialize() -> void:
	var ok := true

	# ── (A) math self-tests ─────────────────────────────────────────────────────────────────
	var h_true := [1.1, 0.08, 14.0, -0.05, 0.97, -9.0, 0.00012, -0.00008, 1.0]
	var src := [Vector2(50, 40), Vector2(800, 60), Vector2(780, 500), Vector2(60, 480),
		Vector2(420, 260), Vector2(200, 350), Vector2(640, 130)]
	var dst := []
	for p in src:
		dst.append(ProjectionMath.apply_h(h_true, p))
	var h_fit := ProjectionMath.fit_homography(src, dst)
	var max_d := 0.0
	for p in src:
		max_d = max(max_d, ProjectionMath.apply_h(h_fit, p).distance_to(ProjectionMath.apply_h(h_true, p)))
	ok = _check("(A) homography fit recovers a known warp (max dev %.6f px)" % max_d, max_d < 1e-3) and ok

	var h_id := ProjectionMath.mat_mul(h_true, ProjectionMath.mat_inv(h_true))
	var id_dev := 0.0
	var h_id_n := ProjectionMath.mat_normalize(h_id)
	for i in 9:
		id_dev = max(id_dev, abs(float(h_id_n[i]) - float(ProjectionMath.mat_identity()[i])))
	ok = _check("(A) H * H^-1 == I (max dev %.12f)" % id_dev, id_dev < 1e-9) and ok

	var pose := ProjectionMath.pose_from([0.4, 3.0, 1.4], [0.0, 1.0, 0.0], null)
	var res := Vector2(960, 540)
	var yfov := deg_to_rad(35.0)
	var surface := {
		"kind": "plane", "origin": [0.0, 1.0, 0.0],
		"rotation": _quat_deg([-35, 0, 0]), "size": [2.4, 1.6],
	}
	var px_in := Vector2(333.0, 222.0)
	var ray := ProjectionMath.px_ray(pose, yfov, res.x / res.y, res, px_in)
	var hit := ProjectionMath.intersect_surface(surface, ray["origin"], ray["dir"])
	ok = _check("(A) projector ray hits the angled plane", bool(hit["hit"])) and ok
	var back := ProjectionMath.project_px(pose, yfov, res.x / res.y, res, hit["point"])
	ok = _check("(A) pixel->ray->plane->pixel round-trips (dev %.5f px)" % (back["px"] as Vector2).distance_to(px_in),
		bool(back["ok"]) and (back["px"] as Vector2).distance_to(px_in) < 1e-3) and ok
	var yf := ProjectionMath.yfov_from_throw(1.0, 1.0)
	ok = _check("(A) throw 1.0 @ 1:1 -> yfov %.1f deg" % rad_to_deg(yf),
		abs(rad_to_deg(yf) - 53.13) < 0.1) and ok

	# ── (B) the arrangement wires up + the misalignment is real ─────────────────────────────
	var arr := _load_arr()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var pattern = out["pattern"]["pattern"]
	ok = _check("(B) CalibrationPattern emits 5x4 = 20 fiducials", (pattern["points"] as Array).size() == 20) and ok
	var projector = out["projector"]["projector"]
	ok = _check("(B) Projector descriptor is DATA (resolution + yfov + pattern + map ride along)",
		typeof(projector) == TYPE_DICTIONARY and projector.has("resolution") and projector.has("yfov")
		and typeof(projector.get("pattern")) == TYPE_DICTIONARY and typeof(projector.get("map")) == TYPE_DICTIONARY) and ok
	ok = _check("(B) descriptor survives JSON round-trip (portable)",
		typeof(JSON.parse_string(JSON.stringify(projector))) == TYPE_DICTIONARY) and ok
	ok = _check("(B) witness camera sees ALL 20 dots land on the surface",
		int(out["observe"]["valid_count"]) == 20) and ok
	var err0 := float(out["calib"]["error"])
	ok = _check("(B) initial misalignment is real: mean error %.2f px > 15" % err0, err0 > 15.0) and ok

	# ── (C) the feedback loop converges ─────────────────────────────────────────────────────
	var run := _run_loop(_load_arr(), MAX_ITERS)
	var errors: Array = run["errors"]
	print("    convergence (gain 0.7): ", _fmt_errors(errors))
	ok = _check("(C) error strictly decreases over the first 3 corrections",
		errors.size() >= 4 and float(errors[1]) < float(errors[0])
		and float(errors[2]) < float(errors[1]) and float(errors[3]) < float(errors[2])) and ok
	ok = _check("(C) converges under %.1f px within %d iterations (final %.3f px)" % [THRESHOLD, MAX_ITERS, float(errors[errors.size() - 1])],
		bool(run["converged"])) and ok

	var arr_g1 := _load_arr()
	_node_params(arr_g1, "calib")["gain"] = 1.0
	var run_g1 := _run_loop(arr_g1, 3)
	var e_g1: Array = run_g1["errors"]
	print("    convergence (gain 1.0): ", _fmt_errors(e_g1))
	ok = _check("(C) gain 1.0 one-shots a planar target to the detector floor (%.3f px after 1 step)" % float(e_g1[1]),
		e_g1.size() >= 2 and float(e_g1[1]) < THRESHOLD) and ok

	# ── (D) determinism ─────────────────────────────────────────────────────────────────────
	var rerun := _run_loop(_load_arr(), MAX_ITERS)
	ok = _check("(D) fresh runtime reproduces the exact error sequence", _fmt_errors(rerun["errors"]) == _fmt_errors(errors)
		and rerun["errors"] == errors) and ok

	# ── (E) oblique handled (35-deg plane is case C); now the CURVED target ─────────────────
	# A cylindrical screen section, with the projector + witness camera re-seated in front of
	# the bulge (same nodes, different DATA — the rig is an arrangement, not code).
	var arr_cyl := _load_arr()
	_node_params(arr_cyl, "surface").clear()
	_node_params(arr_cyl, "surface").merge({ "kind": "cylinder", "origin": [0.0, 1.0, 0.0],
		"rotation": [0.0, 0.0, 0.0], "size": [2.4, 1.6], "radius": 1.2, "arc_deg": 100.0 })
	_node_params(arr_cyl, "projector").clear()
	_node_params(arr_cyl, "projector").merge({ "position": [0.3, 1.6, 3.2], "look_at": [0.0, 1.0, 1.2],
		"yfov": 30.0, "resolution": [960, 540] })
	_node_params(arr_cyl, "view").clear()
	_node_params(arr_cyl, "view").merge({ "position": [-0.5, 1.4, 3.4], "look_at": [0.0, 1.0, 1.2],
		"yfov": 45.0, "znear": 0.05, "zfar": 100.0 })
	var run_cyl := _run_loop(arr_cyl, MAX_ITERS)
	var e_cyl: Array = run_cyl["errors"]
	print("    convergence (cylinder): ", _fmt_errors(e_cyl))
	ok = _check("(E) curved target: the grid still lands + is observed (>= 16 of 20 dots)",
		int(run_cyl["valid_count"]) >= 16) and ok
	ok = _check("(E) curved target: homography loop cuts error to a best-fit floor (%.2f -> %.2f px)" % [float(e_cyl[0]), float(e_cyl[e_cyl.size() - 1])],
		float(e_cyl[e_cyl.size() - 1]) < 0.5 * float(e_cyl[0])) and ok

	# ── (F) proof PNGs (before/after observed view, headless CPU render) ────────────────────
	var proof := _render_proofs(errors)
	ok = _check("(F) before/after/composite proof PNGs written to docs/",
		FileAccess.file_exists(PNG_BEFORE) and FileAccess.file_exists(PNG_AFTER)
		and FileAccess.file_exists(PNG_PROOF)) and ok
	ok = _check("(F) observed views are non-trivial and DIFFER before vs after (mean|d| %.4f)" % proof,
		proof > 0.001) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# ── the loop driver: evaluate -> copy calib.warp into map.params.matrix -> hotload -> repeat ─
# Data-driven iteration (the evolver-tick pattern): the graph stays pure dataflow; the driver
# commits the feedback edge by REWRITING NODE DATA, which the diff-hotload applies in place.
func _run_loop(arr: Dictionary, iters: int) -> Dictionary:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var errors := []
	var converged := false
	var valid := 0
	var warp: Array = ProjectionMath.mat_identity()
	rt.load_arrangement(arr)
	for i in iters:
		var out := rt.evaluate()
		var err := float(out["calib"]["error"])
		valid = int(out["observe"]["valid_count"])
		errors.append(err)
		warp = out["calib"]["warp"]
		if bool(out["calib"]["converged"]):
			converged = true
			break
		_node_params(arr, "map")["matrix"] = warp
		rt.load_arrangement(arr)
	rt.queue_free()
	return { "errors": errors, "converged": converged, "warp": warp, "valid_count": valid }

func _load_arr() -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(ARRANGEMENT))
	assert(typeof(data) == TYPE_DICTIONARY)
	return data

func _node_params(arr: Dictionary, id: String) -> Dictionary:
	for n in arr.get("nodes", []):
		if String(n.get("id")) == id:
			if typeof(n.get("params")) != TYPE_DICTIONARY:
				n["params"] = {}
			return n["params"]
	push_error("no node " + id)
	return {}

# Render the witness camera's observed view with the identity map (before) and the converged
# map (after); save both + a side-by-side composite. Returns the mean |before - after| pixel
# difference (proves the correction is visible, not cosmetic).
func _render_proofs(errors: Array) -> float:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	var imgs := []
	for phase in ["before", "after"]:
		var arr := _load_arr()
		if phase == "after":
			var run := _run_loop(_load_arr(), MAX_ITERS)
			_node_params(arr, "map")["matrix"] = run["warp"]
		var rt := GraphRuntime.new()
		get_root().add_child(rt)
		rt.load_arrangement(arr)
		var out := rt.evaluate()
		var projector: Dictionary = out["projector"]["projector"]
		var input_img := ProjectionRealizer.rasterize_input(projector["pattern"], projector["map"], projector["resolution"])
		var obs := ProjectionRealizer.render_observed(out["view"]["view"], [640, 360],
			out["surface"]["surface"], projector, input_img, out["observe"]["correspondences"])
		imgs.append(obs)
		obs.save_png(PNG_BEFORE if phase == "before" else PNG_AFTER)
		rt.queue_free()
	ProjectionRealizer.side_by_side(imgs[0], imgs[1]).save_png(PNG_PROOF)
	print("    proofs: %s (%.2f px) | %s (%.3f px) | %s" % [
		PNG_BEFORE, float(errors[0]), PNG_AFTER, float(errors[errors.size() - 1]), PNG_PROOF])
	return _mean_abs_diff(imgs[0], imgs[1])

func _mean_abs_diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, a.get_height(), 3):
		for x in range(0, a.get_width(), 3):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			sum += abs(ca.r - cb.r) + abs(ca.g - cb.g) + abs(ca.b - cb.b)
			n += 3
	return sum / float(n)

func _quat_deg(e: Array) -> Array:
	var q := Quaternion.from_euler(Vector3(deg_to_rad(float(e[0])), deg_to_rad(float(e[1])), deg_to_rad(float(e[2]))))
	return [q.x, q.y, q.z, q.w]

func _fmt_errors(errors: Array) -> String:
	var parts := []
	for e in errors:
		parts.append("%.3f" % float(e))
	return " -> ".join(parts)

func _check(label: String, passed: bool) -> bool:
	print(("  PASS  " if passed else "  FAIL  ") + label)
	return passed
