class_name EvolverTick
extends RefCounted
## ONE human-paced STEP of the supervised painterly evolver — the idempotent, resumable orchestrator
## that drives the four primitives over the persistent EvolverState. Safe to re-run any number of times:
## it advances the loop ONLY when the current generation has been fully decided, otherwise it is a no-op
## (re-pushing already-live cards is suppressed). This is what makes the loop human-paced: Liam takes
## time to press buttons, and each tick just checks "are we ready to move on?".
##
## The step (mirroring notes/writing_evolution/v1_design.md's generation algebra):
##   1. LOAD current generation state (seed gen-0 if none).
##   2. RENDER every candidate to a PNG thumbnail (Render2D) — always, so a resume re-materializes thumbs.
##   3. If not yet PUSHED → push each as an Aperture card (ApertureSurface push) + record card↔genome,
##      mark pushed. (In mock mode this writes to a local file; in live mode it hits the real Aperture.)
##   4. READ BACK each card's action (ApertureSurface readback).
##   5. If ALL decided → BREED the next generation (Breed: KEEP/CROSSOVER/INJECT), advance, append
##      lineage, render + push the new generation. Else → leave the generation in place (wait for Liam).
##
## It REUSES the registered primitives directly (instantiated, fed, evaluated) rather than re-implementing
## their logic — the tick is the *driver*; the primitives are the *node system*. The whole thing runs
## headless; `mode` ("mock" | "live") and all params come from a DATA config, so the test runs the EXACT
## same code path as the live surface with only the mode + feedback source swapped.

## Run one tick. cfg keys:
##   state_dir          — gitignored persistence dir (default user://evolver/painterly/).
##   mode               — "mock" (headless/dry-run, default) | "live" (real Aperture).
##   seed               — RNG seed for seeding + breeding (default 1337).
##   meta_genome        — the evolver's params (population_size/n_inject/seed_layers/actions).
##   mock_feedback_path — (mock) the injected fake-feedback file the readback reads.
##   thumb_dir          — where Render2D writes PNGs (default <state_dir>/thumbs).
##   source_path/width/height — Render2D source overrides.
## Returns a report dict: { generation, n_candidates, pushed, all_decided, advanced, next_generation,
##   rendered_ok (bool, every thumbnail written) }.
static func run_once(cfg: Dictionary) -> Dictionary:
	var state_dir := String(cfg.get("state_dir", "user://evolver/painterly/"))
	var mode := String(cfg.get("mode", "mock"))
	var seed := int(cfg.get("seed", 1337))
	var meta: Dictionary = cfg.get("meta_genome", PrimEvolverPopulation.DEFAULT_META.duplicate(true))
	var thumb_dir := String(cfg.get("thumb_dir", state_dir.rstrip("/") + "/thumbs"))

	EvolverState.ensure_dir(state_dir)
	var state := EvolverState.seed_if_empty(state_dir, meta, seed)
	var generation := int(state.get("generation", 0))
	var population: Array = state.get("population", [])

	# 2. RENDER every candidate to a PNG (always — a resume re-materializes thumbs).
	var rendered_desc := _render(population, generation, meta, thumb_dir, cfg)
	var rendered_ok := _all_rendered_ok(rendered_desc)

	# 3. PUSH if not already pushed; else reuse the recorded cards.
	var cards: Array = state.get("cards", [])
	var pushed := bool(state.get("pushed", false))
	if not pushed:
		var push_desc := _push(rendered_desc, mode, cfg)
		cards = push_desc.get("cards", [])
		state["cards"] = cards
		state["pushed"] = true
		pushed = true
		EvolverState.save_state(state_dir, state)

	# 4. READ BACK each card's decision.
	var push_for_readback := {
		"op": "push", "cards": cards, "generation": generation, "meta_genome": meta,
	}
	var readback := _readback(push_for_readback, mode, cfg)
	var all_decided := bool(readback.get("all_decided", false))

	var advanced := false
	var next_generation := generation
	# 5. If fully decided → breed + advance.
	if all_decided:
		var next_pop_desc := _breed(readback, seed)
		var next_population: Array = next_pop_desc.get("population", [])
		if next_population.size() > 0:
			next_generation = int(next_pop_desc.get("generation", generation + 1))
			var next_state := {
				"generation": next_generation,
				"meta_genome": next_pop_desc.get("meta_genome", meta),
				"population": next_population,
				"cards": [],
				"pushed": false,
			}
			EvolverState.save_state(state_dir, next_state)
			EvolverState.append_lineage(state_dir, next_population)
			advanced = true
			# Render + push the NEW generation immediately (so the next tick already has live cards).
			var new_rendered := _render(next_population, next_generation, next_state["meta_genome"], thumb_dir, cfg)
			var new_push := _push(new_rendered, mode, cfg)
			next_state["cards"] = new_push.get("cards", [])
			next_state["pushed"] = true
			EvolverState.save_state(state_dir, next_state)

	return {
		"generation": generation,
		"n_candidates": population.size(),
		"pushed": pushed,
		"all_decided": all_decided,
		"advanced": advanced,
		"next_generation": next_generation,
		"rendered_ok": rendered_ok,
	}

# ---------------------------------------------------------------------------------------------------
# the four node steps — instantiate the registered primitive, feed it, evaluate it
# ---------------------------------------------------------------------------------------------------

static func _render(population: Array, generation: int, meta: Dictionary, thumb_dir: String, cfg: Dictionary) -> Dictionary:
	var pop_node := PrimEvolverPopulation.new()
	pop_node.params = { "population": population, "generation": generation, "meta_genome": meta }
	var pop_out := pop_node.evaluate({})
	var render_node := PrimRender2D.new()
	render_node.params = {
		"out_dir": thumb_dir,
		"source_path": cfg.get("source_path", ""),
		"width": cfg.get("width", PrimRender2D.DEFAULT_W),
		"height": cfg.get("height", PrimRender2D.DEFAULT_H),
	}
	var r := render_node.evaluate({ "population": pop_out.get("population") })
	return r.get("rendered", {})

static func _push(rendered_desc: Dictionary, mode: String, cfg: Dictionary) -> Dictionary:
	var surf := PrimApertureSurface.new()
	surf.params = {
		"op": "push", "mode": mode,
		"mock_dir": cfg.get("mock_dir", String(cfg.get("state_dir", "user://evolver/painterly/")).rstrip("/") + "/mock"),
	}
	var out := surf.evaluate({ "in": rendered_desc })
	return out.get("surface", {})

static func _readback(push_desc: Dictionary, mode: String, cfg: Dictionary) -> Dictionary:
	var surf := PrimApertureSurface.new()
	surf.params = {
		"op": "readback", "mode": mode,
		"mock_feedback_path": cfg.get("mock_feedback_path", ""),
	}
	var out := surf.evaluate({ "in": push_desc })
	return out.get("surface", {})

static func _breed(readback: Dictionary, seed: int) -> Dictionary:
	var breed_node := PrimBreed.new()
	breed_node.params = { "seed": seed }
	var out := breed_node.evaluate({ "in": readback })
	return out.get("population", {})

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

static func _all_rendered_ok(rendered_desc: Dictionary) -> bool:
	var rendered: Array = rendered_desc.get("rendered", [])
	if rendered.is_empty():
		return false
	for entry in rendered:
		if typeof(entry) != TYPE_DICTIONARY or not bool(entry.get("ok", false)):
			return false
	return true
