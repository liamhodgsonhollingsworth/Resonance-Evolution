class_name PrimProjector
extends Primitive
## Emits a renderer-NEUTRAL projector descriptor on the `projector` port — as DATA, never a
## live light/decal. A projector is optically a camera run backwards (same pinhole model as
## the View primitive), so the descriptor mirrors the `view` shape plus the projector-specific
## fields: RESOLUTION, ASPECT, THROW RATIO, and the content it emits (a calibration `pattern`
## wired in, warped by a `map` homography wired in).
##
## The LIVE realization (SpotLight3D + light_projector cookie in Godot) happens in the
## renderer helper (ProjectionRealizer), and the CPU/headless realization (exact pinhole ray
## math) in ProjectionMath — this node is pure data, reusable unchanged for a REAL projector
## rig where the descriptor drives a physical HDMI output instead.
##
## params:
##   position [x,y,z] (m)         — projector placement.
##   look_at  [x,y,z]             — aim point (wins over rotation).
##   rotation [x,y,z] (deg euler) — used when look_at is absent.
##   yfov     (deg)               — vertical field of view of the projected frustum; OR
##   throw_ratio (dist/width)     — the projector spec-sheet number; converted to yfov when
##                                  yfov is absent (aspect-aware).
##   resolution [w,h] (px)        — the projector's native pixel grid (default 960x540).
##   aspect                       — pixel aspect of the frustum (default resolution w/h).
## inputs:
##   pattern (pattern)            — the content descriptor to emit (see CalibrationPattern).
##   map     (projection_map)     — the 2D warp applied to the content before it leaves the
##                                  lens (see ProjectionMap); identity when unwired.
## outputs:
##   projector (projector)        — the full descriptor, self-describing DATA.

const DEFAULT_RESOLUTION := [960, 540]
const DEFAULT_YFOV_DEG := 30.0

func _init() -> void:
	prim_type = "Projector"

func input_ports() -> Array:
	return [
		{ "name": "pattern", "type": "pattern" },
		{ "name": "map", "type": "projection_map" },
	]

func output_ports() -> Array:
	return [{ "name": "projector", "type": "projector" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var res = params.get("resolution", DEFAULT_RESOLUTION)
	var rw := float(res[0])
	var rh := float(res[1])
	var aspect := float(params.get("aspect", rw / max(rh, 1.0)))
	var yfov_rad: float
	if params.has("yfov"):
		yfov_rad = deg_to_rad(float(params.get("yfov")))
	elif params.has("throw_ratio"):
		yfov_rad = ProjectionMath.yfov_from_throw(float(params.get("throw_ratio")), aspect)
	else:
		yfov_rad = deg_to_rad(DEFAULT_YFOV_DEG)
	var desc := {
		"type": "projector",
		"yfov": yfov_rad,
		"aspect": aspect,
		"resolution": [int(rw), int(rh)],
		"position": _v3a(params.get("position", [0.0, 2.0, 1.5])),
		"pattern": inputs.get("pattern"),
		"map": inputs.get("map"),
	}
	if params.has("look_at"):
		desc["look_at"] = _v3a(params.get("look_at"))
	else:
		desc["rotation"] = _v3a(params.get("rotation", [0.0, 0.0, 0.0]))
	if params.has("throw_ratio"):
		desc["throw_ratio"] = float(params.get("throw_ratio"))
	return { "projector": desc }

# Plain 3-array (not Vector3) so the wire value stays JSON-serializable.
func _v3a(a) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	return [0.0, 0.0, 0.0]
