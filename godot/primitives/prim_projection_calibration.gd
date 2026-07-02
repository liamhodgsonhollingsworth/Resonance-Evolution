class_name PrimProjectionCalibration
extends Primitive
## The CORRECTION step of the camera-feedback calibration loop: consumes the observed-vs-
## target correspondences (from ProjectionObserve — simulated OR, later, a real camera+
## detector) and the current warp, and emits (a) the alignment ERROR metric and (b) an
## UPDATED homography for the ProjectionMap. Iterating observe -> calibrate -> re-map is the
## closed loop; error falling under `threshold` is convergence.
##
## Solve (all in ProjectionMath, deterministic):
##   F      = fit_homography(input -> observed)      # how the rig ACTUALLY maps projector px
##                                                   # to camera px right now (the physical map,
##                                                   # estimated purely from what the camera saw)
##   want_i = F^-1(target_i)                         # projector px that WOULD land on target
##   W_full = fit_homography(base -> want)           # the full corrective warp
##   W_new  = blend(W_current, W_full, gain)         # damped feedback step (gain 1 = one-shot)
##
## For a PLANAR surface the projector->camera map is exactly a homography, so gain=1 converges
## in one step (to detector precision); a damped gain shows the classic iterative feedback
## descent and is robust when the surface is only approximately planar (e.g. the curved
## target, where the homography is a best-fit and the loop settles at a floor).
##
## params:
##   gain       0..1  — correction step size (default 1.0).
##   threshold  px    — mean-error convergence threshold (default 1.0).
## inputs:   correspondences (from ProjectionObserve), map (from ProjectionMap).
## outputs:
##   error      — mean |observed - target| in camera px over valid points (-1.0 when fewer
##                than 4 valid points — a detector blackout never crashes the loop).
##   max_error  — worst single fiducial (px), -1.0 when insufficient.
##   warp       — the updated 9-float homography (pattern px -> projector-input px).
##   converged  — bool, error >= 0 and error <= threshold.

func _init() -> void:
	prim_type = "ProjectionCalibration"

func input_ports() -> Array:
	return [
		{ "name": "correspondences", "type": "correspondences" },
		{ "name": "map", "type": "projection_map" },
	]

func output_ports() -> Array:
	return [
		{ "name": "error", "type": "number" },
		{ "name": "max_error", "type": "number" },
		{ "name": "warp", "type": "matrix" },
		{ "name": "converged", "type": "bool" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var current: Array = ProjectionMath.mat_identity()
	var map = inputs.get("map")
	if typeof(map) == TYPE_DICTIONARY and ProjectionMath.mat_is_valid((map as Dictionary).get("matrix")):
		current = (map as Dictionary)["matrix"]
	var corr = inputs.get("correspondences")
	var base_pts := []
	var input_pts := []
	var observed_pts := []
	var target_pts := []
	if corr is Array:
		for rec in corr:
			if typeof(rec) != TYPE_DICTIONARY or not bool((rec as Dictionary).get("valid", false)):
				continue
			base_pts.append(_v2(rec["base"]))
			input_pts.append(_v2(rec["input"]))
			observed_pts.append(_v2(rec["observed"]))
			target_pts.append(_v2(rec["target"]))
	if base_pts.size() < 4:
		return { "error": -1.0, "max_error": -1.0, "warp": current, "converged": false }

	# The error metric FIRST (it describes the state being corrected, not the state after).
	var sum := 0.0
	var worst := 0.0
	for i in observed_pts.size():
		var d: float = (observed_pts[i] as Vector2).distance_to(target_pts[i] as Vector2)
		sum += d
		worst = max(worst, d)
	var err := sum / float(observed_pts.size())

	# The correction: estimate the physical map, invert the targets through it, refit, damp.
	var f := ProjectionMath.fit_homography(input_pts, observed_pts)
	var f_inv := ProjectionMath.mat_inv(f)
	var want := []
	for t in target_pts:
		want.append(ProjectionMath.apply_h(f_inv, t as Vector2))
	var w_full := ProjectionMath.fit_homography(base_pts, want)
	var gain := clampf(float(params.get("gain", 1.0)), 0.0, 1.0)
	var w_new := ProjectionMath.mat_blend(current, w_full, gain)
	var threshold := float(params.get("threshold", 1.0))
	return {
		"error": err,
		"max_error": worst,
		"warp": w_new,
		"converged": err <= threshold,
	}

func _v2(a) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))
