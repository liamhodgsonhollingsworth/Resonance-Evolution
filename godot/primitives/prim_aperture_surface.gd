class_name PrimApertureSurface
extends Primitive
## The APERTURE SURFACE node — the human-in-loop FITNESS seam. It is the connector between the engine's
## evolver and Liam's Aperture: it PUSHES each rendered candidate as an Aperture card (with the X/Evolve/
## Save buttons) and READS BACK the action Liam took on each. The human is the fitness function; this node
## is the wire to it. The actual pixel math (Render2D) and the breeding (Breed) are separate nodes — this
## node owns ONLY the round-trip to the surface.
##
## Two MODES, selected by params.mode (DATA — the implement-both-as-contexts discipline):
##   - "live"  : shells out to the real Wavelet Aperture tools
##               (G:/Wavelet/Alethea-cc/tools/aperture_push.py  +  aperture_feedback.py) via OS.execute,
##               pushing genuine cards to Liam's inbox and polling his real decisions. THE PRODUCTION PATH.
##   - "mock"  : NEVER touches the live Aperture. push() writes the would-be card rows to a local file
##               (params.mock_dir), and readback reads decisions from an injected fake-feedback file
##               (params.mock_feedback_path). The whole data-path cycle is provable headlessly with no UI
##               and no live side effect — the DRY-RUN the headless test runs under. DEFAULT is "mock"
##               (fail-safe: a node that forgets to set the mode can never spam the real inbox).
##
## OPERATION (params.op):
##   - "push"     : for each rendered candidate, emit/record a card { card_id, genome_id, image_path,
##                  actions }. Returns the card↔genome mapping so the generation state can record it.
##   - "readback" : for the given card↔genome mapping, return each card's decided action (or null if
##                  still pending). The action grammar (evolve/save/skip→X) is interpreted downstream
##                  by EvolverBreed, not here — this node is transport-only.
##
## The descriptor it carries — `surface`:
##   push:     { "op":"push", "cards":[ {card_id, genome, image_path, actions} ], "generation", "meta_genome", "pending":[card_id...] }
##   readback: { "op":"readback", "decided":[ {genome, action} ], "all_decided": bool, "cards":[...] }
##
## Adding a new action (a new fitness verb) = a new {id,label} in the meta_genome.actions list + a new
## branch in EvolverBreed.disposition_for — additive, never a foundation edit (the extensibility seam).

const APERTURE_PUSH := "G:/Wavelet/Alethea-cc/tools/aperture_push.py"
const APERTURE_FEEDBACK := "G:/Wavelet/Alethea-cc/tools/aperture_feedback.py"
const SOURCE_TAG := "godot-painterly-evolver"

func _init() -> void:
	prim_type = "ApertureSurface"

func input_ports() -> Array:
	# `in` carries either a `rendered` descriptor (for op=push) or a `surface` push descriptor whose
	# cards we read back (for op=readback). Duck-typed below.
	return [{ "name": "in", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "surface", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var op := String(params.get("op", "push"))
	var mode := String(params.get("mode", "mock"))
	var data = inputs.get("in")
	if op == "readback":
		return { "surface": _readback(data, mode) }
	return { "surface": _push(data, mode) }

# ---------------------------------------------------------------------------------------------------
# push — show each candidate as a card with the X / Evolve / Save buttons
# ---------------------------------------------------------------------------------------------------

func _push(rendered_desc, mode: String) -> Dictionary:
	var rendered: Array = []
	var generation := 0
	var meta := {}
	if typeof(rendered_desc) == TYPE_DICTIONARY and rendered_desc.has("rendered"):
		rendered = rendered_desc.get("rendered", [])
		generation = int(rendered_desc.get("generation", 0))
		meta = rendered_desc.get("meta_genome", {})
	var actions: Array = meta.get("actions", [
		{ "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" },
	])
	var cards: Array = []
	var pending: Array = []
	for entry in rendered:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var genome: Dictionary = entry.get("genome", {})
		var image_path := String(entry.get("image_path", ""))
		var genome_id := String(genome.get("id", ""))
		var title := "Painterly gen %d · %s" % [generation, _short_origin(genome)]
		var subtitle := _stack_caption(genome)
		var card_id := _do_push(mode, title, subtitle, image_path, actions, genome_id, generation)
		cards.append({
			"card_id": card_id,
			"genome": genome,
			"image_path": image_path,
			"actions": actions,
		})
		if card_id != "":
			pending.append(card_id)
	return {
		"op": "push",
		"cards": cards,
		"pending": pending,
		"generation": generation,
		"meta_genome": meta,
	}

## Push one card. live → OS.execute the real aperture_push.py (returns its apx_ id). mock → write the
## would-be card to params.mock_dir and synthesize a deterministic card id (NEVER touches the inbox).
func _do_push(mode: String, title: String, subtitle: String, image_path: String,
		actions: Array, genome_id: String, generation: int) -> String:
	if mode == "live":
		var args := [APERTURE_PUSH, "--source", SOURCE_TAG, "--kind", "artifact",
			"--title", title, "--subtitle", subtitle]
		# A local PNG path → file:// URL so the surface can render the thumbnail.
		var abs_img := ProjectSettings.globalize_path(image_path) if image_path.begins_with("user://") or image_path.begins_with("res://") else image_path
		if abs_img != "":
			args.append("--image-url"); args.append(_file_url(abs_img))
		for a in actions:
			args.append("--action"); args.append("%s:%s" % [String(a.get("id")), String(a.get("label"))])
		var out := []
		var code := OS.execute("py", args, out, true)
		if code != 0:
			code = OS.execute("python3", args, out, true)
		if code != 0:
			push_warning("ApertureSurface: live push failed (code %d): %s" % [code, "\n".join(out)])
			return ""
		# aperture_push.py prints the apx_ id on stdout.
		return "\n".join(out).strip_edges()
	# mock: synthesize a stable card id + record the would-be card to a local file (dry-run proof).
	var card_id := "mock_%d_%s" % [generation, genome_id]
	var mock_dir := String(params.get("mock_dir", "user://evolver/painterly/mock"))
	_ensure_dir(mock_dir)
	var row := {
		"card_id": card_id, "title": title, "subtitle": subtitle,
		"image_path": image_path, "actions": actions, "genome_id": genome_id,
		"generation": generation,
	}
	var f := FileAccess.open(mock_dir.path_join("pushed_cards.jsonl"), FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(mock_dir.path_join("pushed_cards.jsonl"), FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(JSON.stringify(row))
		f.close()
	return card_id

# ---------------------------------------------------------------------------------------------------
# readback — read each card's decided action (evolve/save/skip→X) or null if pending
# ---------------------------------------------------------------------------------------------------

func _readback(push_desc, mode: String) -> Dictionary:
	var cards: Array = []
	var generation := 0
	var meta := {}
	if typeof(push_desc) == TYPE_DICTIONARY and push_desc.has("cards"):
		cards = push_desc.get("cards", [])
		generation = int(push_desc.get("generation", 0))
		meta = push_desc.get("meta_genome", {})
	var decided: Array = []
	var all_decided := true
	for card in cards:
		if typeof(card) != TYPE_DICTIONARY:
			continue
		var card_id := String(card.get("card_id", ""))
		var genome: Dictionary = card.get("genome", {})
		var action = _do_readback(mode, card_id)  # untyped: String or null (pending)
		if action == null:
			all_decided = false
			decided.append({ "genome": genome, "action": null })
		else:
			decided.append({ "genome": genome, "action": action })
	return {
		"op": "readback",
		"decided": decided,
		"all_decided": all_decided,
		"cards": cards,
		"generation": generation,
		"meta_genome": meta,
	}

## Read one card's decision. live → aperture_feedback.py --id <apx>. mock → look the card_id up in the
## injected fake-feedback file (params.mock_feedback_path: JSON { card_id: action } OR jsonl rows
## { "card_id"/"artifact_id", "action" }). Returns the action String, or null if still pending.
func _do_readback(mode: String, card_id: String):
	if card_id == "":
		return null
	if mode == "live":
		var out := []
		var code := OS.execute("py", [APERTURE_FEEDBACK, "--id", card_id], out, true)
		if code != 0:
			code = OS.execute("python3", [APERTURE_FEEDBACK, "--id", card_id], out, true)
		if code != 0:
			return null
		var parsed = JSON.parse_string("\n".join(out))
		if typeof(parsed) == TYPE_DICTIONARY and parsed.has(card_id):
			var row = parsed[card_id]
			if typeof(row) == TYPE_DICTIONARY:
				return String(row.get("action", ""))
		return null
	# mock: read the injected feedback map.
	return _mock_feedback().get(card_id, null)

## Load the injected fake-feedback file (mock mode). Accepts either a flat JSON object { card_id:
## action } or a JSONL of decision rows ({ card_id|artifact_id, action }). Missing/empty → {} (every
## card pending), which is the correct "Liam hasn't pressed anything yet" state.
func _mock_feedback() -> Dictionary:
	var path := String(params.get("mock_feedback_path", ""))
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var as_obj = JSON.parse_string(text)
	if typeof(as_obj) == TYPE_DICTIONARY:
		var flat := {}
		for k in as_obj.keys():
			flat[String(k)] = String(as_obj[k])
		return flat
	# else parse as JSONL rows
	var map := {}
	for line in text.split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			var cid := String(row.get("card_id", row.get("artifact_id", "")))
			if cid != "":
				map[cid] = String(row.get("action", ""))
	return map

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

func _short_origin(genome: Dictionary) -> String:
	return String(genome.get("origin", "seed"))

## A human caption of the genome's effect stack (the layer types in order) for the card subtitle.
func _stack_caption(genome: Dictionary) -> String:
	var stack: Dictionary = genome.get("stack", {})
	var layers: Array = stack.get("stack", [])
	var names: Array = []
	for l in layers:
		if typeof(l) == TYPE_DICTIONARY:
			names.append(String(l.get("type", "?")))
	return " → ".join(names) if names.size() > 0 else "(empty look)"

func _file_url(abs_path: String) -> String:
	var p := abs_path.replace("\\", "/")
	if not p.begins_with("/"):
		p = "/" + p
	return "file://" + p

func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs)
