class_name PrimBreed
extends Primitive
## The BREED node — turns a DECIDED generation (each candidate + the action Liam took) into the NEXT
## generation's `population`. It is the "evolve" step of the loop, and a thin wrapper over the pure
## EvolverBreed.breed algebra (evolver/breed.gd): KEEP survivors + CROSSOVER bookmarked pairs + INJECT
## fresh mutated blood, sized to the meta_genome's population_size. The node owns the wiring; the
## algebra (and the genome operators it reuses) live elsewhere — no breeding math is reimplemented here.
##
## Input — a `surface` readback descriptor: { "decided":[ {genome, action} ], ... }. Only fully-decided
## generations breed (a generation with a pending card stays put — the loop is human-paced); a partial
## readback yields an EMPTY next population, which the tick treats as "not ready yet" (idempotent).
##
## Output — a `population` descriptor for the NEXT generation (generation+1), wired straight back into a
## PrimEvolverPopulation `in` port so the loop closes as an arrangement edge:
##   EvolverPopulation → Render2D → ApertureSurface(push) → … (human) … → ApertureSurface(readback)
##   → Breed → EvolverPopulation(next).
##
## Determinism: the RNG is seeded from params.seed + the generation index, so breeding the SAME decided
## generation always yields the SAME next generation (reproducible evolution — an evolvable invariant).

func _init() -> void:
	prim_type = "Breed"

func input_ports() -> Array:
	return [{ "name": "in", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "population", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var readback = inputs.get("in")
	if typeof(readback) != TYPE_DICTIONARY or readback.get("op") != "readback":
		return { "population": _empty(0, {}) }
	var decided_raw: Array = readback.get("decided", [])
	var meta: Dictionary = _infer_meta(readback)
	# Only breed when EVERY card is decided (human-paced + idempotent: a pending generation is a no-op).
	if not bool(readback.get("all_decided", false)):
		return { "population": _empty(_cur_gen(decided_raw), meta) }
	var cur_gen := _cur_gen(decided_raw)
	var next_gen := cur_gen + 1
	# Rebuild EvolverGenome objects + pair them with the decided action for the breed algebra.
	var decided: Array = []
	for entry in decided_raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var gd = entry.get("genome")
		if typeof(gd) != TYPE_DICTIONARY:
			continue
		var act = entry.get("action")
		decided.append({ "genome": EvolverGenome.from_dict(gd), "action": String(act) if act != null else "" })
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 1337)) + next_gen
	var next_pop: Array = EvolverBreed.breed(decided, meta, next_gen, rng)
	var pop_dicts: Array = []
	for eg in next_pop:
		pop_dicts.append(eg.to_dict())
	return { "population": {
		"population": pop_dicts,
		"generation": next_gen,
		"meta_genome": meta,
	} }

func _empty(generation: int, meta: Dictionary) -> Dictionary:
	return { "population": [], "generation": generation, "meta_genome": meta }

## The current generation index = the max generation among the decided genomes (they were all stamped
## with the same generation when the population was built).
func _cur_gen(decided_raw: Array) -> int:
	var g := 0
	for entry in decided_raw:
		if typeof(entry) == TYPE_DICTIONARY:
			var gd = entry.get("genome", {})
			if typeof(gd) == TYPE_DICTIONARY:
				g = maxi(g, int(gd.get("generation", 0)))
	return g

## The meta_genome to breed under: prefer one carried on the readback (the population's meta rides the
## descriptors), fall back to params.meta_genome, then to PrimEvolverPopulation.DEFAULT_META.
func _infer_meta(readback: Dictionary) -> Dictionary:
	if readback.has("meta_genome") and typeof(readback["meta_genome"]) == TYPE_DICTIONARY and not (readback["meta_genome"] as Dictionary).is_empty():
		return readback["meta_genome"]
	var pm = params.get("meta_genome")
	if typeof(pm) == TYPE_DICTIONARY and not (pm as Dictionary).is_empty():
		return pm
	return PrimEvolverPopulation.DEFAULT_META.duplicate(true)
