extends SceneTree
## RENDER-ONE-GENOME CLI — renders a single serialized genome (an EvolverGenome dict OR a bare
## stack payload) to a PNG, optionally plus K mutated variants. This is the headless render seam
## the Aperture evolution pages call for per-artifact iteration (Liam verbatim spec 2026-07-02
## item 3: open an individual artifact, iterate on it separately, save branches off a generation).
## Pure rendering — no Aperture, no state mutation: the caller owns lineage/branch records.
##
##   godot --headless --path godot -s res://texture_render_cli.gd -- \
##       --genome <abs path to .json> --out-dir <abs dir> [--size 256] [--variants 0] [--seed N]
##
## The genome JSON is either a full EvolverGenome dict ({id, generation, parent_ids, origin,
## stack}) or a bare payload ({texture_ops: [...]} — auto-wrapped). Output lines (stdout):
##   RENDERED base <abs_png> <op-caption>
##   VARIANT <i> <abs_png> <abs_genome_json> <op-caption>     (one per mutated variant)
## Exit 0 iff every render succeeded. Variants are EvolverGenome.inject_mutated children (origin
## "inject", parent = the input genome), each serialized next to its PNG so the caller can save
## any of them as a branch.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var genome_path := _arg(args, "--genome", "")
	var out_dir := _arg(args, "--out-dir", "")
	var size := int(_arg(args, "--size", "256"))
	var variants := int(_arg(args, "--variants", "0"))
	var seed := int(_arg(args, "--seed", str(Time.get_ticks_usec() % 1000000)))
	if genome_path == "" or out_dir == "":
		print("USAGE --genome <abs.json> --out-dir <abs dir> [--size 256] [--variants 0] [--seed N]")
		quit(2)
		return
	var txt := FileAccess.get_file_as_string(genome_path)
	if txt == "":
		print("FAILED read %s" % genome_path)
		quit(1)
		return
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAILED parse %s" % genome_path)
		quit(1)
		return
	var d: Dictionary = parsed
	if not d.has("stack"):
		# bare payload ({texture_ops: [...]} or an effect stack) → wrap into a lineage dict
		d = { "id": "", "generation": int(d.get("generation", 0)), "parent_ids": [],
				"origin": "seed", "stack": d }
	var eg := EvolverGenome.from_dict(d)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var src := PrimRender2D.synthetic_source(size, size)
	var all_ok := true
	var base_png := out_dir.path_join("base.png")
	if PrimRender2D.render_genome_to(eg, base_png, src):
		print("RENDERED base %s %s" % [base_png, _caption(eg)])
	else:
		all_ok = false
		print("FAILED base")
	if variants > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		for i in variants:
			var child := EvolverGenome.inject_mutated(eg, eg.generation, rng)
			var vpng := out_dir.path_join("variant_%d.png" % i)
			var vjson := out_dir.path_join("variant_%d.genome.json" % i)
			var f := FileAccess.open(vjson, FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(child.to_dict(), "\t"))
				f.close()
			if PrimRender2D.render_genome_to(child, vpng, src):
				print("VARIANT %d %s %s %s" % [i, vpng, vjson, _caption(child)])
			else:
				all_ok = false
				print("FAILED variant %d" % i)
	quit(0 if all_ok else 1)

func _caption(eg: EvolverGenome) -> String:
	var names: Array = []
	for op in eg.genome.to_stack().get("texture_ops", []):
		names.append(String((op as Dictionary).get("type", "?")))
	return "+".join(names) if names.size() > 0 else "-"

func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	for i in args.size():
		if args[i] == key and i + 1 < args.size():
			return args[i + 1]
	return fallback
