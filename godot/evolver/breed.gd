class_name EvolverBreed
extends RefCounted
## The BREED algebra — the pure, engine-neutral function that turns a DECIDED generation into the
## NEXT generation. This is the "evolving" half of the GAN-style human-in-loop loop
## (notes/writing_evolution/v1_design.md): the human is the FITNESS (never a detector), expressed by
## three actions per candidate, and breed maps those actions onto the genome operators:
##   - **evolve → KEEP**     : the variant survives as a BREEDER (its look is good; carry it + breed it).
##   - **save   → PIN**      : the variant is PINNED (frozen archive) AND survives as a breeder.
##   - **skip / X → CULL**   : the variant is dropped (does not survive, is not bred from).
##
## The next generation is composed exactly as the spec dictates:
##   next = KEEP survivors (evolve + save)                              ── the elite carry-forward
##        + CROSSOVER of bookmarked (pinned/saved) pairs               ── mix the explicitly-loved looks
##        + INJECT 1..2 fresh MUTATED genomes                          ── new blood, never converge to one
## sized to the population's GEN_STEP (meta_genome.population_size). Every produced child is a real
## EvolverGenome with correct append-only lineage (parent_ids set, origin recorded). Pure DATA + a
## seeded RNG ⇒ deterministic + headless.
##
## It is a FUNCTION OVER DATA, called by PrimBreed (the node). The node owns the wiring; this owns the
## algebra. Adding a new ACTION (a new fitness verb) is a new branch here + a new --action id at the
## surface — additive, never a foundation edit (the extensibility seam).

## Map an Aperture action id onto the breed disposition. The built-in skip/X (no row, or action
## "skip"/"reject"/"cull"/"") is a CULL; "evolve" is KEEP; "save" is PIN. Unknown actions default to
## CULL (conservative: an unrecognized verb never silently breeds — it drops, and the genome is gone
## unless re-seeded, exactly the fail-safe the spec wants).
const ACTION_KEEP := "evolve"
const ACTION_PIN := "save"

static func disposition_for(action: String) -> String:
	match action.strip_edges().to_lower():
		ACTION_KEEP:
			return "keep"
		ACTION_PIN:
			return "pin"
		_:
			return "cull"

## Breed the next generation.
##   decided  : Array of { "genome": EvolverGenome, "action": String } — every card of the current
##              generation with the action Liam took (skip/X arrives as "skip" / "" / "reject").
##   meta     : the evolver's meta_genome (DATA): population_size, n_inject, seed_layers (see PrimEvolverPopulation).
##   next_gen : the generation index to stamp on every child (current + 1).
##   rng      : a seeded RNG (reproducible breeding).
## Returns Array[EvolverGenome] — the next generation's population (size == meta.population_size).
static func breed(decided: Array, meta: Dictionary, next_gen: int, rng: RandomNumberGenerator) -> Array:
	var pop_size := int(meta.get("population_size", 2))
	if pop_size < 1:
		pop_size = 1
	var n_inject := int(meta.get("n_inject", 1))
	n_inject = clampi(n_inject, 0, pop_size)
	var seed_layers := int(meta.get("seed_layers", 3))

	# Partition the decided generation by disposition.
	var survivors: Array = []  # KEEP + PIN (both breed forward)
	var pinned: Array = []     # PIN only (the bookmarked/loved looks crossover gets to mix)
	for entry in decided:
		var eg = entry.get("genome")
		if eg == null:
			continue
		var disp := disposition_for(String(entry.get("action", "")))
		match disp:
			"keep":
				survivors.append(eg.keep_into(next_gen))
			"pin":
				var pinned_eg = eg.pin_into(next_gen)
				survivors.append(pinned_eg)
				pinned.append(eg)  # crossover mixes the ORIGINAL (pre-carry) loved genomes
			_:
				pass  # cull: dropped

	var next: Array = []

	# 1. ELITE carry-forward: every survivor (KEEP + PIN) is taken as-is, capped to leave room for
	#    crossover + inject so the population never overflows pop_size.
	var elite_cap := maxi(0, pop_size - n_inject)
	for s in survivors:
		if next.size() >= elite_cap:
			break
		next.append(s)

	# 2. CROSSOVER the bookmarked (pinned) pairs to fill the middle. With <2 pinned, fall back to
	#    crossing any two survivors so the operator is never starved when Liam pinned just one.
	var cross_pool: Array = pinned if pinned.size() >= 2 else survivors
	while next.size() < (pop_size - n_inject) and cross_pool.size() >= 2:
		var a = cross_pool[rng.randi_range(0, cross_pool.size() - 1)]
		var b = cross_pool[rng.randi_range(0, cross_pool.size() - 1)]
		# crossover takes ORIGINAL-id EvolverGenomes; pinned[] holds originals, survivors[] holds
		# already-carried copies whose ids are fresh — both have a valid id + genome to mix from.
		next.append(EvolverGenome.crossover(a, b, next_gen, rng))

	# 3. INJECT fresh mutated blood — always at least n_inject (spec: 1-2 fresh per generation), so the
	#    population can recover even from a fully-culled generation (mutate a survivor; if none, a fresh
	#    random seed). Fill to pop_size.
	while next.size() < pop_size:
		if survivors.size() > 0:
			var src = survivors[rng.randi_range(0, survivors.size() - 1)]
			next.append(EvolverGenome.inject_mutated(src, next_gen, rng))
		else:
			next.append(EvolverGenome.random_seed(seed_layers, next_gen, rng))

	# Defensive: never exceed pop_size (the loops above guarantee it, but clamp for safety).
	if next.size() > pop_size:
		next = next.slice(0, pop_size)
	return next
