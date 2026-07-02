class_name PrimProjectionSurface
extends Primitive
## A projection TARGET surface as DATA: a plane or a simple curved (cylindrical-section)
## screen with pose + extent. Emits BOTH:
##   `surface`  — the analytic descriptor the CPU projection math intersects (ProjectionMath),
##   `node`     — a renderer-neutral scene_node (primitive mesh) with the SAME pose/extent,
##                so what the live 3D renderer shows and what the math computes provably
##                describe one object.
##
## Local frame convention (matches ProjectionMath): u = +X, v = +Y, outward normal = +Z
## (a "screen" facing +Z); the cylinder's axis is local +Y with the outward bulge toward +Z.
##
## params:
##   kind      "plane" | "cylinder"     (default "plane")
##   origin    [x,y,z] (m)              — surface center.
##   rotation  [x,y,z] (deg euler)      — orients the local frame (e.g. [-35,0,0] tilts the
##                                        screen back like a drafting table).
##   size      [w,h] (m)                — plane extent | cylinder [ignored, height].
##   radius    r (m)                    — cylinder only (default 1.0).
##   arc_deg   a                        — cylinder arc span (default 120).

func _init() -> void:
	prim_type = "ProjectionSurface"

func output_ports() -> Array:
	return [
		{ "name": "surface", "type": "surface" },
		{ "name": "node", "type": "scene_node" },
	]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var kind := String(params.get("kind", "plane"))
	var origin = params.get("origin", [0.0, 0.0, 0.0])
	var rot = params.get("rotation", [0.0, 0.0, 0.0])
	var size = params.get("size", [2.0, 1.5])
	var q := Quaternion.from_euler(Vector3(
		deg_to_rad(float(rot[0])), deg_to_rad(float(rot[1])), deg_to_rad(float(rot[2]))))
	var surface := {
		"kind": kind,
		"origin": [float(origin[0]), float(origin[1]), float(origin[2])],
		"rotation": [q.x, q.y, q.z, q.w],
		"size": [float(size[0]), float(size[1])],
	}
	if kind == "cylinder":
		surface["radius"] = float(params.get("radius", 1.0))
		surface["arc_deg"] = float(params.get("arc_deg", 120.0))
	return { "surface": surface, "node": _scene_node(surface, q) }

## The visual twin: a primitive-mesh scene_node at the same pose. The plane uses Godot's
## PlaneMesh (which faces +Y), pre-rotated +90° about X so its normal lands on the surface's
## local +Z — the descriptor rotation composes on top, so math frame == visual frame.
func _scene_node(surface: Dictionary, q: Quaternion) -> Dictionary:
	var size: Array = surface["size"]
	var mesh: Dictionary
	var rot := q
	if String(surface["kind"]) == "cylinder":
		# A thin tube stands in for the cylindrical screen section (axis already local +Y).
		var r := float(surface.get("radius", 1.0))
		mesh = { "source": "primitive", "shape": "tube", "params": {
			"outer_radius": r, "inner_radius": r * 0.97, "height": float(size[1]) } }
	else:
		mesh = { "source": "primitive", "shape": "plane", "params": {
			"width": float(size[0]), "depth": float(size[1]) } }
		rot = q * Quaternion.from_euler(Vector3(deg_to_rad(90.0), 0.0, 0.0))
	return {
		"name": "projection_surface",
		"translation": surface["origin"].duplicate(),
		"rotation": [rot.x, rot.y, rot.z, rot.w],
		"scale": [1.0, 1.0, 1.0],
		"mesh": mesh,
		"children": [],
	}
