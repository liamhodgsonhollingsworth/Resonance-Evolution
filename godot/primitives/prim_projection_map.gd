class_name PrimProjectionMap
extends Primitive
## The reusable PROJECTION-MAPPING warp node for the whole projection family (video projector
## here; the laser arc's galvo point-warp later): holds a 2D HOMOGRAPHY from content pixel
## space to projector-input pixel space, as DATA. The camera-feedback calibration loop WRITES
## this node's matrix (each iteration updates params.matrix — data-driven, hotload-diff safe);
## the Projector applies it to everything it emits.
##
## params:
##   matrix [9 floats, row-major]  — the current warp (default identity = no correction).
## inputs:
##   warp (matrix)                 — optional live override (a wire wins over params, so the
##                                   map can sit inside a graph-native feedback loop through a
##                                   State node as well as the data-driven iteration).
## outputs:
##   map — { kind:"homography", "matrix": [9], "inverse": [9] } (inverse precomputed so
##          downstream consumers never re-invert per point).

func _init() -> void:
	prim_type = "ProjectionMap"

func input_ports() -> Array:
	return [{ "name": "warp", "type": "matrix" }]

func output_ports() -> Array:
	return [{ "name": "map", "type": "projection_map" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var m = inputs.get("warp")
	if not ProjectionMath.mat_is_valid(m):
		m = params.get("matrix")
	if not ProjectionMath.mat_is_valid(m):
		m = ProjectionMath.mat_identity()
	var norm := ProjectionMath.mat_normalize(m as Array)
	return { "map": {
		"kind": "homography",
		"matrix": norm,
		"inverse": ProjectionMath.mat_inv(norm),
	} }
