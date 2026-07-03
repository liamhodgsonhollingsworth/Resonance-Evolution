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
# The wrapped look-genome. GENOME-KIND-POLYMORPHIC (2026-07-02): an EffectGenome (the painterly
# post-process stack), a TextureGenome (the procedural-texture op list), or a NodeGenome (the
# node-collection artifact whose connections are also nodes, with concentrating adaptive
# per-param distributions — 2026-07-03) — all expose the same duck-typed contract
# (clone/mutate/to_stack/is_valid + static random/crossover/from_stack), so the lineage record,
# the breed algebra, and the four evolver primitives drive any kind unchanged. The serialized
# discriminator is the payload key: "stack" → effect, "texture_ops" → texture, "node_graph" → node.
var genome = null
var generation: int = 0
var parent_ids: Array = []
var origin: String = "seed"

func _init(p_genome = null, p_id: String = "", p_generation: int = 0,
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
## INJECT brand-new blood when breeding. `kind` selects the genome family ("effect" default —
## fully backward-compatible — "texture", or "node"); carried on meta_genome.genome_kind by callers.
static func random_seed(n_layers: int, gen: int, rng: RandomNumberGenerator, kind: String = "effect") -> EvolverGenome:
	if kind == "texture":
		return EvolverGenome.new(TextureGenome.random(n_layers, rng), "", gen, [], "seed")
	if kind == "node":
		return EvolverGenome.new(NodeGenome.random(n_layers, rng), "", gen, [], "seed")
	return EvolverGenome.new(EffectGenome.random(n_layers, rng), "", gen, [], "seed")

## Which genome FAMILY this variant carries: "node" | "texture" | "effect". The render delegate
## dispatches on this; everything else is kind-blind.
func kind() -> String:
	if genome is NodeGenome:
		return "node"
	return "texture" if genome is TextureGenome else "effect"

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
## the actual mix to the genome family's own crossover — the look operator is reused, never rebuilt.
## Mixed-kind parents do NOT interbreed (no cross-family splice is defined): the child degrades to a
## clone of `a` (a degenerate cross), lineage still recorded.
static func crossover(a: EvolverGenome, b: EvolverGenome, next_gen: int, rng: RandomNumberGenerator) -> EvolverGenome:
	var child_genome
	if a.kind() != b.kind():
		child_genome = a.genome.clone()
	elif a.genome is TextureGenome:
		child_genome = TextureGenome.crossover(a.genome, b.genome, rng)
	elif a.genome is NodeGenome:
		child_genome = NodeGenome.crossover(a.genome, b.genome, rng)
	else:
		child_genome = EffectGenome.crossover(a.genome, b.genome, rng)
	return EvolverGenome.new(child_genome, "", next_gen, [a.id, b.id], "crossover")

## INJECT fresh blood by MUTATING a source variant (origin "inject", source recorded as the parent).
## Delegates the local edit to EffectGenome.mutate.
static func inject_mutated(src: EvolverGenome, next_gen: int, rng: RandomNumberGenerator) -> EvolverGenome:
	var mutated = src.genome.mutate(rng)  # untyped: the wrapped genome is kind-polymorphic
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
	# Kind dispatch on the payload key: "texture_ops" rebuilds a TextureGenome, "node_graph" a
	# NodeGenome; anything else is the original effect-stack path (unchanged for every
	# pre-existing serialized genome).
	var payload = d.get("stack", { "stack": [] })
	var g
	if typeof(payload) == TYPE_DICTIONARY and payload.has("texture_ops"):
		g = TextureGenome.from_stack(payload)
	elif typeof(payload) == TYPE_DICTIONARY and payload.has("node_graph"):
		g = NodeGenome.from_stack(payload)
	else:
		g = EffectGenome.from_stack(payload)
	return EvolverGenome.new(
		g,
		String(d.get("id", "")),
		int(d.get("generation", 0)),
		(d.get("parent_ids", []) as Array),
		String(d.get("origin", "seed")),
	)
