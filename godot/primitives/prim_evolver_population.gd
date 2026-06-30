class_name PrimEvolverPopulation
extends Primitive
## The POPULATION node — holds one GENERATION of the painterly evolver as DATA and emits it as a
## `population` descriptor. This is the genome STORE of the supervised-evolver arrangement: the
## genomes of the current generation, plus the evolver's OWN params (the `meta_genome`), live entirely
## in `params` (pure DATA, hot-reloadable/editable/evolvable) — nothing is baked into the node's code.
##
## The descriptor it emits:
##   { "population": [ <EvolverGenome.to_dict()>, ... ],   # the current generation's variants
##     "generation": int,                                   # which generation this is
##     "meta_genome": { ... } }                             # the evolver's params (see below)
##
## --- THE META-GENOME (the meta-evolution SEAM) ---------------------------------------------------
## `params.meta_genome` is the evolver's OWN genome — its tunable params, as DATA on the node:
##   { "population_size": int,   # N candidates per generation (the GEN_STEP; default 2)
##     "n_inject":        int,   # fresh mutated genomes injected each breed (1-2; default 1)
##     "seed_layers":     int,   # layer count of a fresh random seed genome (default 3)
##     "actions": [ {"id","label"}, ... ] }  # the per-card button set Liam sees (X is the built-in skip)
## These are the knobs a FUTURE meta-evolution driver would itself mutate from Liam's selection history
## (do MORE of what he keeps, LESS of what he culls). That driver is NOT built here (no
## auto-generalization) — this node only PROVIDES the seam: the params live in DATA, and
## `meta_genome()` is the single read point a driver would hook. See EVOLVER-LOOP.md "Meta-evolution".
##
## Adding a new evolver knob = a new key in meta_genome (read by breed / the surface), never a code
## edit here. Adding a new candidate = a new entry in params.population. The node is a dumb DATA holder.

const DEFAULT_META := {
	"population_size": 2,
	"n_inject": 1,
	"seed_layers": 3,
	"actions": [
		{ "id": "evolve", "label": "Evolve" },
		{ "id": "save", "label": "Save" },
	],
}

func _init() -> void:
	prim_type = "EvolverPopulation"

func input_ports() -> Array:
	# Optional upstream population to ADOPT (so a Breed node's output can feed straight back in as the
	# next generation — the loop closes through a wire). Unconnected → emit params.population.
	return [{ "name": "in", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "population", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var upstream = inputs.get("in")
	if typeof(upstream) == TYPE_DICTIONARY and upstream.has("population"):
		# Adopt an upstream generation verbatim (the breed→render loop edge). Its meta rides along.
		return { "population": _normalize(upstream) }
	# Otherwise emit the genomes held in params, with the meta_genome merged over the defaults.
	var pop: Array = []
	for g in params.get("population", []):
		if typeof(g) == TYPE_DICTIONARY:
			pop.append((g as Dictionary).duplicate(true))
	var desc := {
		"population": pop,
		"generation": int(params.get("generation", 0)),
		"meta_genome": meta_genome(),
	}
	return { "population": desc }

## The merged meta-genome: params.meta_genome over DEFAULT_META (so a partial override only changes the
## keys it names). THE meta-evolution read point — a future driver mutates params.meta_genome and the
## whole loop picks up the new evolver params on the next hotload, no code change.
func meta_genome() -> Dictionary:
	var m := DEFAULT_META.duplicate(true)
	var override: Dictionary = params.get("meta_genome", {})
	for k in override.keys():
		m[k] = override[k]
	return m

## Coerce an upstream population dict into the canonical descriptor (defaults filled, meta merged).
func _normalize(upstream: Dictionary) -> Dictionary:
	var meta: Dictionary = DEFAULT_META.duplicate(true)
	var um: Dictionary = upstream.get("meta_genome", {})
	for k in um.keys():
		meta[k] = um[k]
	return {
		"population": (upstream.get("population", []) as Array).duplicate(true),
		"generation": int(upstream.get("generation", 0)),
		"meta_genome": meta,
	}

## Whether a wire value is a population descriptor (structural duck-test, mirroring
## PrimEffectStack.is_effect_stack — no class coupling on the data path).
static func is_population(v) -> bool:
	return typeof(v) == TYPE_DICTIONARY and v.has("population") and typeof(v["population"]) == TYPE_ARRAY
