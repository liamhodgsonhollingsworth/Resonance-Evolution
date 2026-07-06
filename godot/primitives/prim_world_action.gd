class_name PrimWorldAction
extends Primitive
## The WORLD ACTION node — the wirable side-effect SINK (Dreams-arc Slice 1). It is the exact sibling
## of PrimApertureAction: a thin, param-configured wire around a shared writer module (WorldActions),
## proving that a param-configured side-effect sink is legal inside evaluate() and stays a normal
## dataflow node (its output `result` is a serialisable receipt, never a live node or a signal).
##
## params:  { "op": String (default op if the `op` input is unwired), plus any op-specific defaults
##            like "target"/"key"/"message" that the wired inputs override }.
## inputs:  op (verb string), value (the payload for `log`), target/key/value (for `set_param`).
## output:  result — the WorldActions receipt dict ({ ok, op, ... }; unknown op => a declared no-op).
##
## The op CATALOG is WorldActions' registry, not this file: a new world effect is a new registered op
## (a host registers `device.*` at boot; a later slice registers the wide catalog), NEVER an edit here.
## An unwired/unknown op is a declared no-op, so the same arrangement runs on any host (the portability
## keystone WorldActions documents).

const WorldActions := preload("res://runtime/world_actions.gd")

func _init() -> void:
	prim_type = "WorldAction"

func input_ports() -> Array:
	return [
		{ "name": "op", "type": "any" },       # verb string: log / set_param / (host ops) — overrides params.op
		{ "name": "value", "type": "any" },    # payload (the log message / the set_param value)
		{ "name": "target", "type": "any" },   # set_param: the node id to write to
		{ "name": "key", "type": "any" },      # set_param: the param key to write
	]

func output_ports() -> Array:
	return [{ "name": "result", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var op := String(inputs.get("op", params.get("op", "noop")))
	# Merge params defaults with wired inputs (wired inputs WIN), exactly as PrimApertureAction resolves
	# its action/comment. Only non-null wire values override, so an unwired port falls back to params.
	var args: Dictionary = {}
	for k in ["message", "target", "key", "value"]:
		if params.has(k):
			args[k] = params[k]
	if inputs.get("value") != null:
		args["value"] = inputs["value"]
		# `log` reads either `message` or `value`; mirror the wired value into message when none is set.
		if not args.has("message"):
			args["message"] = inputs["value"]
	if inputs.get("target") != null:
		args["target"] = inputs["target"]
	if inputs.get("key") != null:
		args["key"] = inputs["key"]
	var writer := WorldActions.new(params)
	return { "result": writer.perform(op, args) }
