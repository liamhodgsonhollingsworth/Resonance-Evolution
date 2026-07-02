class_name StereoRig
extends Node3D
## The live-camera / VR seam for the stereo viewing-geometry model — the SAME parameter dict
## PrimStereoRender consumes (screen_distance_m, ipd_m, screen size, clip planes) drives two
## live Godot Camera3Ds in off-axis (asymmetric-frustum) stereo, converged exactly on the
## screen/focal plane. This is the identical projection the CPU pair renderer uses, on the GPU —
## the intended host wiring is two side-by-side SubViewports for a live windowed preview.
##
## THE OPENXR SEAM (documented, not brought up here — headset testing is out of scope):
## - A real headset does NOT take these frusta: OpenXR supplies per-eye transforms + projection
##   matrices itself (hardware IPD, per-eye FOV) via XROrigin3D/XRCamera3D.
## - The geometry dict still maps onto XR:
##     ipd_m / hardware_ipd     → XROrigin3D.world_scale (deliberate hyper/hypo-stereo);
##     screen_distance_m + screen_width_m → the virtual screen quad you place in-world when
##       showing flat stereo content (texture the stereogram onto that quad at distance D and
##       the in-headset free-viewing geometry physically matches the generator's parameters);
##     znear_m / zfar_m         → camera clip planes.
## - eye_descriptors(geo) below is the ONE function both this preview rig and a future XR
##   adapter read, so no output mode grows private geometry.
##
## See notes/design/stereogram_vr_viewer_2026-07-02.md for the derivations.

var left: Camera3D = null
var right: Camera3D = null

## Pure data: per-eye camera descriptors from the geometry dict (defaults applied via
## PrimStereoRender.derive). Off-axis frustum math:
##   near-plane height  size    = screen_height_m · znear / D
##   near-plane offset  offset  = (−eye_x · znear / D, 0)   [toward the shared screen window]
static func eye_descriptors(geo_in: Dictionary) -> Dictionary:
	var geo := PrimStereoRender.derive(geo_in)
	var d := float(geo["screen_distance_m"])
	var zn := float(geo["znear_m"])
	var out := {}
	for side in ["left", "right"]:
		var eye_x := (-1.0 if side == "left" else 1.0) * float(geo["ipd_m"]) / 2.0
		out[side] = {
			"position": [eye_x, 0.0, 0.0],
			"frustum_size": float(geo["screen_height_m"]) * zn / d,
			"frustum_offset": [-eye_x * zn / d, 0.0],
			"znear": zn,
			"zfar": float(geo["zfar_m"]),
		}
	out["geometry"] = geo
	return out

## Build (once) + drive the two live Camera3Ds from the dict. Re-calling re-drives the SAME
## camera instances (hotload discipline: re-wire, never rebuild).
func apply(geo_in: Dictionary) -> Dictionary:
	var desc := eye_descriptors(geo_in)
	if left == null or not is_instance_valid(left):
		left = Camera3D.new()
		left.name = "EyeL"
		add_child(left)
	if right == null or not is_instance_valid(right):
		right = Camera3D.new()
		right.name = "EyeR"
		add_child(right)
	_drive(left, desc["left"])
	_drive(right, desc["right"])
	return desc

static func _drive(cam: Camera3D, d: Dictionary) -> void:
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.size = float(d["frustum_size"])
	cam.frustum_offset = Vector2(float(d["frustum_offset"][0]), float(d["frustum_offset"][1]))
	cam.near = float(d["znear"])
	cam.far = float(d["zfar"])
	var p: Array = d["position"]
	cam.transform = Transform3D(Basis.IDENTITY, Vector3(float(p[0]), float(p[1]), float(p[2])))
