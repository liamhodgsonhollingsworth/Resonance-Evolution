class_name EvolverGenome
extends RefCounted
## A LINEAGE-BEARING wrapper around an EffectGenome — the unit the supervised painterly evolver
## breeds. The EffectGenome (renderers/effect_genome.gd) is the pure look DATA (the ordered effect
## stack + mutate/crossover); this adds the EVOLUTION-RECORD around it so a generation is an
## APPEND-ONLY lineage, not a flat list of looks:
##   - `id`          — a stable unique id for THIS exact variant (so a card maps back to a genome).
##   - `generation`  — the generation index this variant was born into (monotone, never rewritten).
##   - `parent_ids`  — the ids of the genome(s) this one descends from (a KEEP carries its own id; a
##                     CROSSOVER carries both parents; an INJECT carries its mutated source). Once set
##                     it is NEVER mutated — that is the append-only invariant at the genome level.
##   - `origin`      — how this variant was produced: "seed" | "keep" | "pin" | "crossover" | "inject".
##
## It is pure DATA + pure functions over data (no Image, no Godot type on the wire) — the whole
## breed/serialize/resume path runs HEADLESS and is deterministic given a seeded RNG, exactly like the
## EffectGenome it wraps. `to_dict()`/`from_dict()` round-trip through JSON so the entire lineage
## persists to (and resumes from) the gitignored state dir.
##
## NOTHING here re-implements the look operators — mutate/crossover delegate to the wrapped
## EffectGenome, so adding a new effect layer (one edit in EffectStackCpu.EFFECT_TYPES) automatically
## extends what the lineage evolves. The evolver is an ARRANGEMENT over the existing genome, not a
## parallel genome.

var id: String = ""
var genome: EffectGenome = null
var generation: int = 0
var parent_ids: Array = []
var origin: String = "seed"

func _init(p_genome: EffectGenome = null, p_id: String = "", p_generation: int = 0,
		p_parent_ids: Array = [], p_origin: String = "seed") -> void:
	genome = p_genome if p_genome != null else EffectGenome.new([])
	id = p_id if p_id != "" else EvolverGenome.new_id()
	generation = p_generation
	# Copy the parent-id list so no caller can later mutate our recorded lineage (append-only).
	parent_ids = (p_parent_ids as Array).duplicate()
	origin = p_origin

# ---------------------------------------------------------------------------------------------------
# ids
# ---------------------------------------------------------------------------------------------------

static var _counter: int = 0

## A process-unique, sortable id. Deterministic ONLY in shape (not value across runs) — a genome's id
## is its identity, not part of the reproducible look, so it does not need to be seeded.
static func new_id() -> String:
	_counter += 1
	return "gen_%d_%d" % [Time.get_ticks_usec(), _counter]

# ---------------------------------------------------------------------------------------------------
# breeding — each returns a NEW EvolverGenome with correct lineage; sources are untouched
# ---------------------------------------------------------------------------------------------------

## A fresh random seed variant (origin "seed", no parents). Used to populate generation 0 and to
## INJECT brand-new blood when breeding.
static func random_seed(n_layers: int, gen: int, rng: RandomNumberGenerator) -> EvolverGenome:
	return EvolverGenome.new(EffectGenome.random(n_layers, rng), "", gen, [], "seed")

## KEEP this variant forward into the next generation UNCHANGED (origin "keep"). The survivor itself is
## the breeder; its parent is its own prior id (the lineage chain records "I came from me at gen-1").
func keep_into(next_gen: int) -> EvolverGenome:
	return EvolverGenome.new(genome.clone(), "", next_gen, [id], "keep")

## PIN this variant: an exact, frozen archive of the look (origin "pin"). Same look as keep, but the
## origin distinguishes "Liam explicitly saved this one" from "kept as a breeder". A pin is ALSO a
## breeder (it carries the genome forward), so save = keep + archive.
func pin_into(next_gen: int) -> EvolverGenome:
	return EvolverGenome.new(genome.clone(), "", next_gen, [id], "pin")

## CROSSOVER two survivors into a new variant (origin "crossover", both parents recorded). Delegates
## the actual mix to EffectGenome.crossover — the look operator is reused, never rebuilt.
static func crossover(a: EvolverGenome, b: EvolverGenome, next_gen: int, rng: RandomNumberGenerator) -> EvolverGenome:
	var child_genome := EffectGenome.crossover(a.genome, b.genome, rng)
	return EvolverGenome.new(child_genome, "", next_gen, [a.id, b.id], "crossover")

## INJECT fresh blood by MUTATING a source variant (origin "inject", source recorded as the parent).
## Delegates the local edit to EffectGenome.mutate.
static func inject_mutated(src: EvolverGenome, next_gen: int, rng: RandomNumberGenerator) -> EvolverGenome:
	var mutated := src.genome.mutate(rng)
	return EvolverGenome.new(mutated, "", next_gen, [src.id], "inject")

# ---------------------------------------------------------------------------------------------------
# serialization — round-trips through JSON so the lineage persists + resumes
# ---------------------------------------------------------------------------------------------------

func to_dict() -> Dictionary:
	return {
		"id": id,
		"generation": generation,
		"parent_ids": parent_ids.duplicate(),
		"origin": origin,
		"stack": genome.to_stack(),
	}

static func from_dict(d: Dictionary) -> EvolverGenome:
	var g := EffectGenome.from_stack(d.get("stack", { "stack": [] }))
	return EvolverGenome.new(
		g,
		String(d.get("id", "")),
		int(d.get("generation", 0)),
		(d.get("parent_ids", []) as Array),
		String(d.get("origin", "seed")),
	)
