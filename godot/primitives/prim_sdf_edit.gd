class_name PrimSdfEdit
extends Primitive
## The SDF EDIT node — one signed-distance-field edit (shape + transform + CSG op + blend radius +
## material) authored entirely as DATA, emitted as an EDIT-LIST descriptor. Modelled on PrimLSystem's
## param-node shape: a generator with no required inputs that EMITS renderer-neutral JSON data (no
## engine objects on the wire), computed through a pure math module (renderers/sdf.gd, SDF). Optionally
## takes an incoming `edits` list (the field-so-far) and APPENDS its own edit, so a chain of these
## nodes IS the sculpt history — reorder / edit a node and the field changes, no new code.
##
## IT DOES NOT RENDER. It stops at DATA: the emitted `edits` array is the input a later sculpt / voxel /
## splat slice (the visuals session's lane) evaluates into geometry via SDF.field_distance. This node's
## whole job is to produce that edit-list contract.
##
## params:
##   shape     — sphere | box | round_box | torus | cylinder | plane. Default "sphere".
##   op        — CSG op vs the field so far: add (union) | subtract | intersect. Default "add".
##   blend     — smooth-min blend radius k (0 = hard CSG; >0 rounds the seam). Default 0.0.
##   transform — { position:[x,y,z], scale:float, rotation:[x,y,z,w]? }. Places the shape.
##   material  — opaque DATA carried through to the consumer (e.g. { albedo, roughness }). Default {}.
##   sphere:    { radius }        box/round_box: { half_extents:[hx,hy,hz], radius? }
##   torus:     { major, minor }  cylinder: { radius, height }   plane: { normal:[x,y,z], offset }
## input  "edits" (optional): the incoming edit-list (the field so far) this node appends to.
## output "edits": the incoming list + this node's edit, in order (an SDF.EDIT_FORMAT descriptor list).

func _init() -> void:
	prim_type = "SdfEdit"

func input_ports() -> Array:
	return [{ "name": "edits", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "edits", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	# Copy the incoming list (never mutate an upstream wire value) then append this node's edit.
	var incoming = inputs.get("edits")
	var out: Array = []
	if incoming is Array:
		for e in incoming:
			out.append(e)
	out.append(_edit())
	return { "edits": out }

## This node's single edit, as a plain-dict descriptor stamped with the edit-list format tag.
func _edit() -> Dictionary:
	return {
		"format": SDF.EDIT_FORMAT,
		"shape": String(params.get("shape", "sphere")),
		"op": String(params.get("op", "add")),
		"blend": float(params.get("blend", 0.0)),
		"transform": params.get("transform", { "position": [0, 0, 0], "scale": 1.0 }),
		"params": params.get("params", {}),
		"material": params.get("material", {}),
	}

## Pure: the emitted edit-list is a deterministic function of (incoming edits, params), no side
## effect — it produces DATA, it does not render. Safe to memoize like Const/Math.
func is_cacheable() -> bool:
	return true
