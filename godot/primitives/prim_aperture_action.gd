class_name PrimApertureAction
extends Primitive
## The APERTURE ACTION node — records a card decision (skip/✕, bookmark/★, evolve, save, cull,
## unskip, ...) through the SAME channel the web board uses, as a wirable node. A thin wire
## around ApertureActions (the shared write module): params carry the channel config
## ({mode:"http"|"file", base_url | feedback_path+bookmarks_path, by}), inputs carry the card
## + action, output `result` is the write receipt. Pointed at a temp dir in file mode this is
## the zero-pollution mock path the headless test drives.

func _init() -> void:
	prim_type = "ApertureAction"

func input_ports() -> Array:
	return [
		{ "name": "card", "type": "any" },     # normalized card dict (or {"id": ...})
		{ "name": "action", "type": "any" },   # verb string: skip/bookmark/evolve/save/...
	]

func output_ports() -> Array:
	return [{ "name": "result", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var card = inputs.get("card")
	if typeof(card) == TYPE_STRING:
		card = { "id": card }
	if typeof(card) != TYPE_DICTIONARY:
		return { "result": { "ok": false, "error": "card input required" } }
	var action := String(inputs.get("action", params.get("action", "")))
	var writer := ApertureActions.new(params)
	return { "result": writer.act(card, action, String(params.get("comment", ""))) }
