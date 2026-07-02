class_name PrimCalibrationPattern
extends Primitive
## A structured CALIBRATION PATTERN as DATA: a cols x rows grid of fiducial dots in the
## pattern's own normalized UV space ([0,1]^2, origin top-left, +v down — image convention).
## The projector rasterizes it (via ProjectionRealizer) and the observe/calibration nodes
## consume the SAME point list, so "what was projected" and "what should be detected" come
## from one source of truth. Known-correspondence fiducials (id -> uv) are the simplest
## robust structured-light pattern; Gray-code/ArUco are later pattern KINDS behind this same
## port, not new machinery.
##
## params:
##   cols, rows    — fiducial grid dimensions (default 5 x 4).
##   margin        — border inset in pattern UV (default 0.12).
##   dot_radius    — dot radius as a fraction of pattern width, for rasterization (default 0.012).
## outputs:
##   pattern       — { kind:"fiducial_grid", cols, rows, margin, dot_radius,
##                     points: [ { id, u, v }, ... ] }

func _init() -> void:
	prim_type = "CalibrationPattern"

func output_ports() -> Array:
	return [{ "name": "pattern", "type": "pattern" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var cols := int(params.get("cols", 5))
	var rows := int(params.get("rows", 4))
	cols = max(cols, 2)
	rows = max(rows, 2)
	var margin := clampf(float(params.get("margin", 0.12)), 0.0, 0.45)
	var points := []
	for r in rows:
		for c in cols:
			var u := margin + (1.0 - 2.0 * margin) * float(c) / float(cols - 1)
			var v := margin + (1.0 - 2.0 * margin) * float(r) / float(rows - 1)
			points.append({ "id": r * cols + c, "u": u, "v": v })
	return { "pattern": {
		"kind": "fiducial_grid",
		"cols": cols,
		"rows": rows,
		"margin": margin,
		"dot_radius": float(params.get("dot_radius", 0.012)),
		"points": points,
	} }
