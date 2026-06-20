class_name PortTypes
extends RefCounted
## The typed-port vocabulary shared by every primitive. A port has a semantic type
## name (e.g. "number", "model"); ports connect only when compatible. This is what
## makes "anything connects to anything compatible" real, and (per the plan) it maps
## directly onto Godot GraphEdit's integer slot types + add_valid_connection_type()
## when the in-game editor is built in Phase 2.
##
## Compatibility rule (widening-only, per the Apeiron port contract): same type always
## connects; "any" accepts everything; and a few explicit one-way widenings are allowed
## (a narrower type may feed a wider one, never the reverse). Types may be ADDED later
## without breaking existing wires — this is a deliberate extensibility seam.

# Semantic type name -> integer slot id (used by GraphEdit.set_slot in Phase 2).
const TYPE_IDS := {
	"any": 0,
	"number": 1,
	"bool": 2,
	"vector3": 3,
	"transform": 4,
	"color": 5,
	"model": 6,
	"image": 7,
	"signal": 8,
	"scene_node": 9,
}

# One-way widenings beyond same-type and "any" (from_type -> [allowed to_type ...]).
const WIDENINGS := {
	"bool": ["number"],
}

static func type_id(type_name: String) -> int:
	return TYPE_IDS.get(type_name, 0)

static func compatible(from_type: String, to_type: String) -> bool:
	if to_type == "any" or from_type == to_type:
		return true
	return (WIDENINGS.get(from_type, []) as Array).has(to_type)
