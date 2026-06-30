extends SceneTree
## CLI entrypoint for ONE human-paced tick of the supervised painterly evolver. Idempotent + resumable:
## load the current generation, render thumbnails, push cards if not yet pushed, read back decisions, and
## breed+advance only when the whole generation is decided. Safe to run on a schedule or by hand.
##
##   # mock/dry-run (NEVER touches the live Aperture — for verification):
##   godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode mock \
##         --state-dir user://evolver/painterly --feedback <fake_feedback.json>
##   # live (pushes real cards to Liam's Aperture + polls his real decisions):
##   godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode live \
##         --state-dir user://evolver/painterly
##
## Args (after `--`): --mode mock|live, --state-dir <path>, --seed <int>, --feedback <path> (mock),
##   --pop <int> (population_size), --inject <int> (n_inject), --source <image path>.
## Defaults: mode=mock, state-dir=user://evolver/painterly, seed=1337, pop/inject from DEFAULT_META.

func _initialize() -> void:
	var cfg := _parse_args()
	var report := EvolverTick.run_once(cfg)
	print("[evolver_tick] ", JSON.stringify(report))
	quit(0)

func _parse_args() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	var cfg := {
		"mode": "mock",
		"state_dir": "user://evolver/painterly",
		"seed": 1337,
	}
	var meta := PrimEvolverPopulation.DEFAULT_META.duplicate(true)
	var i := 0
	while i < args.size():
		var a := String(args[i])
		match a:
			"--mode":
				i += 1; cfg["mode"] = String(args[i]) if i < args.size() else "mock"
			"--state-dir":
				i += 1; cfg["state_dir"] = String(args[i]) if i < args.size() else cfg["state_dir"]
			"--seed":
				i += 1; cfg["seed"] = int(String(args[i])) if i < args.size() else 1337
			"--feedback":
				i += 1; cfg["mock_feedback_path"] = String(args[i]) if i < args.size() else ""
			"--source":
				i += 1; cfg["source_path"] = String(args[i]) if i < args.size() else ""
			"--pop":
				i += 1; meta["population_size"] = int(String(args[i])) if i < args.size() else 2
			"--inject":
				i += 1; meta["n_inject"] = int(String(args[i])) if i < args.size() else 1
		i += 1
	cfg["meta_genome"] = meta
	return cfg
