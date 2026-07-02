class_name EvolverState
extends RefCounted
## The PERSISTENT, human-paced STATE of the painterly evolver — load + save + advance one generation,
## all under a GITIGNORED dir (NEVER a git-tracked file: host launchers `git reset --hard` on restart and
## would wipe accumulated generations; this is a load-bearing Wavelet lesson). The loop is async: Liam
## takes time to press buttons, so the run is a stateful document on disk that the tick resumes.
##
## On-disk layout (under params.state_dir, default user://evolver/painterly/):
##   state.json   — the CURRENT generation:
##                  { "generation": int, "meta_genome": {...}, "population": [<EvolverGenome.to_dict()>],
##                    "cards": [ {card_id, genome_id, image_path, actions} ],   # set after a push
##                    "pushed": bool }                                          # whether cards are live
##   lineage.jsonl — APPEND-ONLY: every genome ever born, one row each (the full lineage, never rewritten).
##
## The tick (EvolverTick) is the only writer; this class is the pure load/save/seed/advance API it calls.
## Everything is JSON DATA, so a run is fully inspectable + resumable (re-running the tick resumes the
## exact same state — idempotent).

## Resolve a state-dir path (res:// / user:// / absolute) to an absolute filesystem path.
static func abs_dir(state_dir: String) -> String:
	if state_dir.begins_with("res://") or state_dir.begins_with("user://"):
		return ProjectSettings.globalize_path(state_dir)
	return state_dir

static func _state_file(state_dir: String) -> String:
	return abs_dir(state_dir).path_join("state.json")

static func _lineage_file(state_dir: String) -> String:
	return abs_dir(state_dir).path_join("lineage.jsonl")

static func ensure_dir(state_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(abs_dir(state_dir))

# ---------------------------------------------------------------------------------------------------
# load / save
# ---------------------------------------------------------------------------------------------------

## Load the current state, or {} if none exists yet (a fresh run → caller seeds generation 0).
static func load_state(state_dir: String) -> Dictionary:
	var path := _state_file(state_dir)
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

## Atomically persist the current state (write sibling .tmp, then replace — never a half-written file a
## resume could choke on).
static func save_state(state_dir: String, state: Dictionary) -> void:
	ensure_dir(state_dir)
	var path := _state_file(state_dir)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("EvolverState: cannot open %s for write" % tmp)
		return
	f.store_string(JSON.stringify(state, "\t"))
	f.close()
	DirAccess.rename_absolute(tmp, path)

## Append each genome of a generation to the append-only lineage log (never mutates a prior row).
static func append_lineage(state_dir: String, population: Array) -> void:
	ensure_dir(state_dir)
	var path := _lineage_file(state_dir)
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("EvolverState: cannot open lineage log %s" % path)
		return
	f.seek_end()
	for gd in population:
		f.store_line(JSON.stringify(gd))
	f.close()

## Read the whole lineage back (for assertions / inspection).
static func read_lineage(state_dir: String) -> Array:
	var path := _lineage_file(state_dir)
	if not FileAccess.file_exists(path):
		return []
	var rows: Array = []
	for line in FileAccess.get_file_as_string(path).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			rows.append(row)
	return rows

# ---------------------------------------------------------------------------------------------------
# seed — generation 0
# ---------------------------------------------------------------------------------------------------

## Seed a fresh generation-0 state of population_size random genomes, persist it + log the lineage, and
## return it. Deterministic given the seed. Does nothing if a state already exists (resume-safe).
static func seed_if_empty(state_dir: String, meta: Dictionary, seed: int) -> Dictionary:
	var existing := load_state(state_dir)
	if not existing.is_empty():
		return existing
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pop_size := int(meta.get("population_size", 2))
	var seed_layers := int(meta.get("seed_layers", 3))
	# meta_genome.genome_kind selects the genome family gen-0 is seeded from: "effect" (default,
	# the painterly stack — unchanged behavior) or "texture" (the procedural-texture op genome).
	var genome_kind := String(meta.get("genome_kind", "effect"))
	var population: Array = []
	for _i in maxi(1, pop_size):
		population.append(EvolverGenome.random_seed(seed_layers, 0, rng, genome_kind).to_dict())
	var state := {
		"generation": 0,
		"meta_genome": meta,
		"population": population,
		"cards": [],
		"pushed": false,
	}
	save_state(state_dir, state)
	append_lineage(state_dir, population)
	return state
