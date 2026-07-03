class_name EvolverSubstrate
extends RefCounted
## The SHARED EVOLUTION SUBSTRATE — pure-data twin of the web evolution API
## (Resonance-Website static/aperture/endpoints/evolver.py, branch feat/aperture-evolution-pages).
## The web page and the in-engine evolution room are TWO VIEWS OF THE SAME FILES; every record
## shape and file location here matches that module byte-for-byte so either surface reads what
## the other wrote:
##
##   <state_dir>/*_cards.jsonl   card→genome map rows { card_id, genome_id, generation }
##                               (glob-sorted, last-wins — later generations supersede)
##   <state_dir>/lineage.jsonl   append-only EvolverGenome dicts { id, generation, parent_ids,
##                               origin, stack } (last-wins by id)
##   <state_dir>/branches.jsonl  append-only BRANCH records (schema below — the exact record
##                               evolver.py _handle_branch writes and read_branches reads)
##
## BRANCH RECORD (one JSON object per line, append-only, never rewritten):
##   { "branch_id": "br_<8 hex>", "card_id": "apx_...", "source_genome_id": "gen_..."|null,
##     "off_generation": int, "genome": { id:"gen_<usec>_br", generation, parent_ids:[source],
##     "origin":"branch", stack }, "image": "G:/...png"|null, "note": "..."|null,
##     "created_at": ISO-8601Z, "by": "liam", "origin": "branch" }
##
## The default state dir is the ONE dir both lanes point at: the web STATE_DIR env default is
## G:\Wavelet\repos\Resonance-Evolution\godot\state\evolver\textures, which IS
## res://state/evolver/textures when the engine runs from the main checkout.
##
## Grouping semantics mirror evolver.py _handle_index exactly: EVERY latest inbox row of
## kind=evolver_candidate (decided cards stay, annotated `decided`/`decision` — the evolution
## page shows history, the main board hides decided), grouped by generation ascending with the
## unknown-generation bucket ("?") last.

const DEFAULT_STATE_DIR := "res://state/evolver/textures"

# ---------------------------------------------------------------------------------------------------
# reads — the same joins evolver.py performs
# ---------------------------------------------------------------------------------------------------

## card_id → { card_id, genome_id, generation } from every *_cards.jsonl (glob-sorted, last-wins).
static func card_genome_map(state_dir: String) -> Dictionary:
	var out := {}
	var abs := _abs(state_dir)
	var d := DirAccess.open(abs)
	if d == null:
		return out
	var names: Array = []
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.ends_with("_cards.jsonl"):
			names.append(f)
		f = d.get_next()
	d.list_dir_end()
	names.sort()  # mirrors sorted(STATE_DIR.glob("*_cards.jsonl"))
	for name in names:
		for row in _read_jsonl(abs.path_join(String(name))):
			var cid := String(row.get("card_id", ""))
			if cid != "":
				out[cid] = row
	return out

## genome_id → full EvolverGenome dict from the append-only lineage log (last-wins by id).
static func genome_by_id(state_dir: String) -> Dictionary:
	var out := {}
	for row in _read_jsonl(_abs(state_dir).path_join("lineage.jsonl")):
		var gid := String(row.get("id", ""))
		if gid != "":
			out[gid] = row
	return out

static func branches_path(state_dir: String) -> String:
	return _abs(state_dir).path_join("branches.jsonl")

static func read_branches(state_dir: String) -> Array:
	return _read_jsonl(branches_path(state_dir))

static func branches_for(state_dir: String, card_id: String) -> Array:
	var out: Array = []
	for b in read_branches(state_dir):
		if String(b.get("card_id", "")) == card_id:
			out.append(b)
	return out

## Human caption = the op-type chain (e.g. "fbm+sine+sine") — mirror of _genome_caption.
static func genome_caption(genome) -> String:
	if typeof(genome) != TYPE_DICTIONARY:
		return ""
	var stack = genome.get("stack", genome)
	if typeof(stack) != TYPE_DICTIONARY:
		return ""
	var ops = stack.get("texture_ops")
	if typeof(ops) != TYPE_ARRAY:
		return ""
	var names: Array = []
	for op in ops:
		if typeof(op) == TYPE_DICTIONARY:
			names.append(String(op.get("type", "?")))
	return "+".join(names)

# ---------------------------------------------------------------------------------------------------
# the evolution index — evolver rows grouped by generation (mirror of _handle_index)
# ---------------------------------------------------------------------------------------------------

## Latest feedback action per artifact id ({ id: action }) — the annotation join decisions_for
## performs on the web side (latest-wins per id, same rows aperture_feedback.py reads).
static func latest_decisions(feedback_path: String) -> Dictionary:
	var latest := {}
	if feedback_path == "" or not FileAccess.file_exists(feedback_path):
		return latest
	for line in FileAccess.get_file_as_string(feedback_path).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var id := String(row.get("artifact_id", ""))
		var act := String(row.get("action", "")).strip_edges().to_lower()
		if id != "" and act != "":
			latest[id] = act
	return latest

## ALL latest inbox rows (last-wins by id, NO hide/status filter — the evolution page shows
## decided cards annotated, unlike the main board), kind-filtered to evolver_candidate,
## normalized via ApertureInbox.normalize_card, then joined with genome + decision + caption.
static func evolver_rows(inbox_path: String, feedback_path: String, state_dir: String) -> Array:
	var by_id := {}
	var order: Array = []
	for row in _read_jsonl(inbox_path):
		var id := String(row.get("id", ""))
		if id == "":
			continue
		if not by_id.has(id):
			order.append(id)
		by_id[id] = row
	var decisions := latest_decisions(feedback_path)
	var cmap := card_genome_map(state_dir)
	var gmap := genome_by_id(state_dir)
	var out: Array = []
	for id in order:
		var raw: Dictionary = by_id[id]
		if String(raw.get("kind", "")) != "evolver_candidate":
			continue
		var card := ApertureInbox.normalize_card(raw)
		out.append(annotate_row(card, decisions, cmap, gmap))
	return out

## The genome/decision/caption join for ONE normalized card (shared by the file path above and
## the http path, where the server already grouped but the engine re-joins local media).
static func annotate_row(card: Dictionary, decisions: Dictionary, cmap: Dictionary, gmap: Dictionary) -> Dictionary:
	var id := String(card.get("id", ""))
	card["decided"] = decisions.has(id)
	card["decision"] = String(decisions.get(id, ""))
	var link: Dictionary = cmap.get(id, {})
	var gid := String(link.get("genome_id", ""))
	card["genome_id"] = gid
	if int(card.get("generation", -1)) < 0 and link.has("generation"):
		card["generation"] = int(link.get("generation"))
	var genome = gmap.get(gid) if gid != "" else null
	card["genome"] = genome
	card["caption"] = genome_caption(genome)
	return card

## Group annotated rows by generation — ascending, unknown ("?") last; mirror of _handle_index.
## Returns [ { "generation": String, "cards": Array } ].
static func group_by_generation(rows: Array) -> Array:
	var groups := {}
	var keys: Array = []
	for r in rows:
		var gen := int((r as Dictionary).get("generation", -1))
		var key := "?" if gen < 0 else str(gen)
		if not groups.has(key):
			groups[key] = []
			keys.append(key)
		(groups[key] as Array).append(r)
	keys.sort_custom(func(a, b) -> bool:
		if String(a) == "?":
			return false
		if String(b) == "?":
			return true
		return int(String(a)) < int(String(b)))
	var out: Array = []
	for k in keys:
		out.append({ "generation": String(k), "cards": groups[k] })
	return out

# ---------------------------------------------------------------------------------------------------
# save-as-branch — the exact append evolver.py _handle_branch performs
# ---------------------------------------------------------------------------------------------------

## Append ONE branch record for `card_id` forking off `genome` (an EvolverGenome dict or a bare
## {texture_ops} stack). Returns the record written (ok=false + error on invalid input).
## Field-for-field the web _handle_branch record: same keys, same id shapes, same normalization
## (a NEW lineage-ready genome with parent_ids=[source_genome_id], origin "branch").
static func append_branch(state_dir: String, card_id: String, genome: Dictionary,
		off_generation: int = -1, image: String = "", note: String = "") -> Dictionary:
	if card_id == "" or genome.is_empty():
		return { "ok": false, "error": "card_id and genome required" }
	var link: Dictionary = card_genome_map(state_dir).get(card_id, {})
	var source_gid := String(link.get("genome_id", ""))
	var off_gen := off_generation
	if off_gen < 0:
		off_gen = int(link.get("generation", 0))
	var stack = genome.get("stack", genome if genome.has("texture_ops") else null)
	var saved_genome := {
		"id": "gen_%d_br" % int(Time.get_unix_time_from_system() * 1000000.0),
		"generation": off_gen,
		"parent_ids": [source_gid] if source_gid != "" else [],
		"origin": "branch",
		"stack": stack if typeof(stack) == TYPE_DICTIONARY else genome,
	}
	var record := {
		"branch_id": "br_" + _hex8(),
		"card_id": card_id,
		"source_genome_id": source_gid if source_gid != "" else null,
		"off_generation": off_gen,
		"genome": saved_genome,
		"image": image if image != "" else null,
		"note": note if note != "" else null,
		"created_at": ApertureActions.now_iso(),
		"by": "liam",
		"origin": "branch",
	}
	var path := branches_path(state_dir)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return { "ok": false, "error": "cannot open " + path }
	f.seek_end()
	f.store_line(JSON.stringify(record))
	f.close()
	var out := record.duplicate()
	out["ok"] = true
	return out

# ---------------------------------------------------------------------------------------------------
# util
# ---------------------------------------------------------------------------------------------------

## Map a web media URL ("/api/aperture/media?path=G%3A%2F...") back to the LOCAL path it serves;
## anything else passes through. Mirror-inverse of the web's media_url_for — the local path is the
## identity, the URL is a serving detail (same rule _handle_branch applies on the web side).
static func media_url_to_local(url: String) -> String:
	if url.begins_with("/api/aperture/media?path="):
		return url.substr("/api/aperture/media?path=".length()).uri_decode()
	return url

## 8 lowercase hex chars (the web uses uuid4().hex[:8] — shape-equal, crypto-random).
static func _hex8() -> String:
	var bytes := Crypto.new().generate_random_bytes(4)
	return bytes.hex_encode()

static func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path

static func _read_jsonl(path: String) -> Array:
	var out: Array = []
	var abs := _abs(path)
	if not FileAccess.file_exists(abs):
		return out
	for line in FileAccess.get_file_as_string(abs).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out
