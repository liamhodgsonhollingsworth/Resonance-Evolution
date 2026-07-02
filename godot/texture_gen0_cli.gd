extends SceneTree
## GENERATION-0 CLI for the procedural-texture evolver — seeds (or resumes) a texture generation
## under the GITIGNORED state dir and renders every candidate to a full-size PNG tile, printing one
## machine-readable line per candidate so a driver (shell / Python / a session) can push the tiles
## as Aperture cards and later map card feedback back to genome ids. Rendering only — this CLI never
## touches the Aperture itself (pushing is the driver's job; separation keeps the render path pure).
##
##   godot --headless --path godot -s res://texture_gen0_cli.gd -- \
##       [--state-dir res://state/evolver/textures] [--seed 20260702] [--count 8] [--size 256]
##
## Output lines (stdout, one per candidate):
##   CANDIDATE <genome_id> <abs_png_path> <op-caption>
## State persists via EvolverState (state.json + append-only lineage.jsonl), so a later tick can
## read Liam's decisions and breed generation 1 from the exact same genomes.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var state_dir := _arg(args, "--state-dir", "res://state/evolver/textures")
	var seed := int(_arg(args, "--seed", "20260702"))
	var count := int(_arg(args, "--count", "8"))
	var size := int(_arg(args, "--size", "256"))

	var meta := {
		"population_size": count,
		"n_inject": 1,
		"seed_layers": 3,
		"genome_kind": "texture",
		"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ],
	}
	EvolverState.ensure_dir(state_dir)
	var state := EvolverState.seed_if_empty(state_dir, meta, seed)
	var generation := int(state.get("generation", 0))
	var out_dir := EvolverState.abs_dir(state_dir).path_join("gen%d" % generation)
	DirAccess.make_dir_recursive_absolute(out_dir)

	var src := PrimRender2D.synthetic_source(size, size)
	var all_ok := true
	for gd in state.get("population", []):
		var eg := EvolverGenome.from_dict(gd)
		var png := out_dir.path_join("%s.png" % eg.id)
		if PrimRender2D.render_genome_to(eg, png, src):
			print("CANDIDATE %s %s %s" % [eg.id, png, _caption(eg)])
		else:
			all_ok = false
			print("FAILED %s" % eg.id)
	print("GENERATION %d COUNT %d STATE %s" % [generation, (state.get("population", []) as Array).size(), EvolverState.abs_dir(state_dir)])
	quit(0 if all_ok else 1)

func _caption(eg: EvolverGenome) -> String:
	var names: Array = []
	for op in eg.genome.to_stack().get("texture_ops", []):
		names.append(String((op as Dictionary).get("type", "?")))
	return "+".join(names)

func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	for i in args.size():
		if args[i] == key and i + 1 < args.size():
			return args[i + 1]
	return fallback
