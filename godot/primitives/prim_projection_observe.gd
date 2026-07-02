class_name PrimProjectionObserve
extends Primitive
## The SIMULATED CAMERA-FEEDBACK observation step: a witness camera (a View descriptor)
## watches the projection surface and reports WHERE each projected fiducial actually landed
## in ITS image, alongside where that fiducial SHOULD land (the target). This is the
## "camera" in camera-feedback calibration, in mode "sim": the projector -> surface -> camera
## light transport is computed exactly with the CPU pinhole model (ProjectionMath), which is
## what makes the loop testable headless against ground truth. A REAL rig later swaps this
## node's mode for a physical camera + dot detector emitting the SAME correspondence records —
## the calibration solver downstream never changes (the camera-swappable seam the drum arc +
## laser arc reuse).
##
## Transport per fiducial (u,v):
##   base     = (u,v) in projector-input pixels (the unwarped pattern position)
##   input    = map.matrix applied to base (what the projector actually emits)
##   observed = camera-projection( surface-hit( projector-ray(input) ) )   [+ quantization]
##   target   = camera-projection( surface_point(target_rect(u,v)) )
## The intended placement (targets) maps the pattern onto `target_rect` in surface-uv space —
## i.e. "the grid should land on THIS region of the physical screen", the same anchor role
## printed/marked fiducials play on a real rig.
##
## params:
##   resolution  [w,h] px  — the witness camera sensor grid (default 640x360).
##   target_rect [u0,v0,u1,v1] — where on the surface (uv space) the pattern should land
##                               (default [0.25, 0.25, 0.75, 0.75]).
##   quantize    px        — round observed positions to this grid, simulating finite
##                           detector precision (default 0.0 = exact; try 0.25).
## inputs:  projector (from Projector), surface (from ProjectionSurface), view (from View).
## outputs:
##   correspondences — [ { id, base:[x,y], input:[x,y], observed:[x,y], target:[x,y],
##                         valid: bool }, ... ]  (px; valid=false when the dot missed the
##                       surface, fell behind the camera, or left the camera frame)
##   valid_count     — how many correspondences a detector would actually have seen.

func _init() -> void:
	prim_type = "ProjectionObserve"

func input_ports() -> Array:
	return [
		{ "name": "projector", "type": "projector" },
		{ "name": "surface", "type": "surface" },
		{ "name": "view", "type": "view" },
	]

func output_ports() -> Array:
	return [
		{ "name": "correspondences", "type": "correspondences" },
		{ "name": "valid_count", "type": "number" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var projector = inputs.get("projector")
	var surface = inputs.get("surface")
	var view = inputs.get("view")
	if typeof(projector) != TYPE_DICTIONARY or typeof(surface) != TYPE_DICTIONARY \
			or typeof(view) != TYPE_DICTIONARY:
		return { "correspondences": [], "valid_count": 0 }
	var pattern = (projector as Dictionary).get("pattern")
	if typeof(pattern) != TYPE_DICTIONARY:
		return { "correspondences": [], "valid_count": 0 }

	var proj_pose := projector_pose(projector)
	var proj_res := Vector2(float(projector["resolution"][0]), float(projector["resolution"][1]))
	var proj_yfov := float(projector.get("yfov", deg_to_rad(30.0)))
	var proj_aspect := float(projector.get("aspect", proj_res.x / proj_res.y))

	var cam_pose := view_pose(view)
	var cam_res_p = params.get("resolution", [640, 360])
	var cam_res := Vector2(float(cam_res_p[0]), float(cam_res_p[1]))
	var cam_yfov := float(view.get("yfov", deg_to_rad(45.0)))
	var cam_aspect := cam_res.x / cam_res.y

	var warp: Array = ProjectionMath.mat_identity()
	var map = (projector as Dictionary).get("map")
	if typeof(map) == TYPE_DICTIONARY and ProjectionMath.mat_is_valid((map as Dictionary).get("matrix")):
		warp = (map as Dictionary)["matrix"]

	var rect = params.get("target_rect", [0.25, 0.25, 0.75, 0.75])
	var quant := float(params.get("quantize", 0.0))

	var out := []
	var valid_count := 0
	for pt in (pattern as Dictionary).get("points", []):
		var u := float(pt["u"])
		var v := float(pt["v"])
		var base := Vector2(u * proj_res.x, v * proj_res.y)
		var input := ProjectionMath.apply_h(warp, base)
		var rec := {
			"id": int(pt["id"]),
			"base": [base.x, base.y],
			"input": [input.x, input.y],
			"observed": [0.0, 0.0],
			"target": [0.0, 0.0],
			"valid": false,
		}
		# Target: pattern-uv mapped into target_rect on the surface (pattern +v is image-DOWN,
		# surface +v is UP, so the v axis flips), then seen through the camera.
		var su := float(rect[0]) + u * (float(rect[2]) - float(rect[0]))
		var sv := float(rect[3]) - v * (float(rect[3]) - float(rect[1]))
		var tgt := ProjectionMath.surface_point(surface, Vector2(su, sv))
		var tproj := ProjectionMath.project_px(cam_pose, cam_yfov, cam_aspect, cam_res, tgt["point"])
		if tproj["ok"]:
			rec["target"] = [tproj["px"].x, tproj["px"].y]
		# Observation: emit the warped dot through the projector, land it, watch it.
		var ray := ProjectionMath.px_ray(proj_pose, proj_yfov, proj_aspect, proj_res, input)
		var hit := ProjectionMath.intersect_surface(surface, ray["origin"], ray["dir"])
		if hit["hit"] and tproj["ok"]:
			var oproj := ProjectionMath.project_px(cam_pose, cam_yfov, cam_aspect, cam_res, hit["point"])
			if oproj["ok"]:
				var opx: Vector2 = oproj["px"]
				if quant > 0.0:
					opx = Vector2(floorf(opx.x / quant + 0.5) * quant, floorf(opx.y / quant + 0.5) * quant)
				if opx.x >= 0.0 and opx.x < cam_res.x and opx.y >= 0.0 and opx.y < cam_res.y:
					rec["observed"] = [opx.x, opx.y]
					rec["valid"] = true
					valid_count += 1
		out.append(rec)
	return { "correspondences": out, "valid_count": valid_count }

## Pose of a projector descriptor (position + look_at | euler rotation). Static + shared so
## the realizer / tests build the identical pose from the identical data.
static func projector_pose(projector: Dictionary) -> Transform3D:
	return ProjectionMath.pose_from(
		projector.get("position", [0, 0, 0]),
		projector.get("look_at"),
		projector.get("rotation", [0, 0, 0]))

## Pose of a View descriptor ({transform:{translation,rotation}, look_at?}).
static func view_pose(view: Dictionary) -> Transform3D:
	var trs: Dictionary = view.get("transform", {})
	var pos = trs.get("translation", [0, 0, 0])
	if view.has("look_at"):
		return ProjectionMath.pose_from(pos, view.get("look_at"), null)
	var q = trs.get("rotation", [0, 0, 0, 1])
	return Transform3D(
		Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized()),
		Vector3(float(pos[0]), float(pos[1]), float(pos[2])))
