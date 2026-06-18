class_name Primitive
extends Node
## Base class for every primitive node in the Resonance substrate.
##
## A primitive is the smallest unit of functionality. It declares typed input and
## output ports and computes its outputs from its inputs (pure dataflow). Behavior /
## event primitives (Phase 2+) additionally wire Godot signals; that is layered on
## top of this contract, not a replacement for it.
##
## A primitive is also a self-contained, portable plugin: it carries no hidden global
## state and exchanges only serializable values across ports, so a node or a cluster
## of nodes can later be lifted out and shared. NOTHING in this base is colour / skin /
## model specific.

## The registered type name (e.g. "Const", "Math", "Model"). Set in subclass _init().
var prim_type: String = "Primitive"

## Declarative parameters from the arrangement data (e.g. {"op": "add"}).
var params: Dictionary = {}

## Input ports: an Array of { "name": String, "type": String }. See PortTypes.
func input_ports() -> Array:
	return []

## Output ports: an Array of { "name": String, "type": String }.
func output_ports() -> Array:
	return []

## Pure dataflow step. Given input-port-name -> value, return output-port-name -> value.
## Override in subclasses. Must not mutate `inputs`.
func evaluate(_inputs: Dictionary) -> Dictionary:
	return {}

## Coerce a possibly-null wire value (unconnected inputs arrive as null) to a float.
static func as_num(v) -> float:
	if v == null:
		return 0.0
	match typeof(v):
		TYPE_FLOAT, TYPE_INT, TYPE_BOOL:
			return float(v)
		TYPE_STRING:
			return (v as String).to_float()
	return 0.0
