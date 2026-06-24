class_name PrimState
extends Primitive
## The one explicitly STATEFUL module — a unit-delay / register (a hardware z^-1, an FBP feedback
## cell). Its output "value" is what it currently HOLDS; its input "next" is what it will hold after
## the tick/sim handler commits at the tick boundary. Keeping simulation memory in a NAMED MODULE —
## not in the runtime floor, not hidden inside a handler — is what keeps "everything is a module"
## true for simulation: a sim's state is a wireable, inspectable, content-addressable node like any
## other (see COMMUNICATION-ARCHITECTURE.md, the tick/sim section).
##
## It is a CYCLE-BREAKING SOURCE: evaluate() returns the held value WITHOUT reading "next", so a
## feedback loop State -> ... -> State is a SEQUENTIAL element (one step per tick), not a combinational
## cycle that the topo-sort would choke on. The tick/sim Context handler drives the boundary: each
## tick it evaluates the scope (State outputs are the sources), then reads each State's "next" input
## from the computed outputs and commit()s it as the new held value. reset_state() restores params.init
## (the "sim"/reproducible handler re-inits every outer evaluation; "tick"/continuous does not).
##
## params shape: { "init": <any> }   (the value held before the first commit; default 0)

## The currently-held value. Mutable instance state — this module IS the state; the floor stays pure.
var _held: Variant = null
var _initialized: bool = false

func _init() -> void:
	prim_type = "State"

func input_ports() -> Array:
	return [{ "name": "next", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "value", "type": "any" }]

## Pull the held value. Ignores "next" by design (that is committed at the tick boundary, not read
## here) — which is precisely what makes State a cycle-breaking source.
func evaluate(_inputs: Dictionary) -> Dictionary:
	if not _initialized:
		_held = params.get("init", 0)
		_initialized = true
	return { "value": _held }

## Adopt the next held value. Called by the tick/sim handler at the tick boundary, never by dataflow.
func commit(next_value: Variant) -> void:
	_held = next_value
	_initialized = true

## Restore the initial value (the reproducible "sim" handler calls this before each outer evaluation,
## so each run is a pure function of init + inputs + steps).
func reset_state() -> void:
	_held = params.get("init", 0)
	_initialized = true

## Time-varying by construction: a scope containing a State node is never a pure function of its
## inputs alone, so the abstract handler must never memoize it (it degrades to a live scope instead).
func is_cacheable() -> bool:
	return false
