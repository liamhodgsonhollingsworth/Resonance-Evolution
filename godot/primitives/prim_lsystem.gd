class_name PrimLSystem
extends Primitive
## The L-SYSTEM node — axiom + production rules + iteration depth + turtle interpretation as DATA in
## (see renderers/lsystem.gd), ONE renderer-neutral scene_node out: a group of oriented primitive
## cylinders (the branching geometry), the same descriptor shape Model / PartsCatalog emit — so it
## wires into Transform / Group / the delegate exactly like any other scene source. Deterministic +
## seeded (stochastic [weight, replacement] rule options are drawn from a seeded LCG).
##
## params:
##   axiom   — the start string (e.g. "X").
##   rules   — { symbol: replacement | [[weight, replacement], ...] }.
##   depth   — rewrite iterations.
##   seed    — the stochastic-choice seed (ignored by plain string rules).
##   turtle  — { step, angle_deg, radius, radius_decay, step_decay }.
##   name    — the group name on the emitted scene_node (default "lsystem").
## output "node": the scene_node descriptor (pure JSON data, no engine objects on the wire).

func _init() -> void:
	prim_type = "LSystem"

func input_ports() -> Array:
	return []

func output_ports() -> Array:
	return [{ "name": "node", "type": "scene_node" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var axiom := String(params.get("axiom", "X"))
	var rules: Dictionary = params.get("rules", {})
	var depth := int(params.get("depth", 3))
	var seed := int(params.get("seed", 0))
	var turtle: Dictionary = params.get("turtle", {})
	var symbols := LSystem.expand(axiom, rules, depth, seed)
	var segments := LSystem.interpret(symbols, turtle)
	return { "node": LSystem.to_scene_node(segments, String(params.get("name", "lsystem"))) }
