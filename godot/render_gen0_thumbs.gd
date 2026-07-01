extends SceneTree
## One-shot headless renderer: seed N=4 painterly EffectGenomes (gen 0) and render each to a PNG
## thumbnail via the proven EffectStackCpu oracle, writing them to godot/docs/evolver_gen0/N.png
## (a NON-gitignored docs path, so they are committed + servable via GitHub raw URLs).
##
## This is the ONE-TIME gen-0 seeding for the LIVE Aperture launch — it uses the SAME seed + genome
## primitives the evolver_tick uses (EvolverGenome.random_seed + EffectStackCpu.apply over the
## deterministic synthetic source), so the pictures Liam judges are exactly what the loop will breed
## from. It does NOT touch the evolver state dir or the Aperture — it only writes PNGs.
##
##   godot --headless --path godot -s res://render_gen0_thumbs.gd -- --out docs/evolver_gen0 --n 4 --seed 1337 --size 512

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_rel := "docs/evolver_gen0"
	var n := 4
	var seed := 1337
	var size := 512
	var source_rel := ""   # optional res://-relative real source image (richer than the synthetic gradient)
	var i := 0
	while i < args.size():
		match String(args[i]):
			"--out": i += 1; out_rel = String(args[i]) if i < args.size() else out_rel
			"--n": i += 1; n = int(String(args[i])) if i < args.size() else n
			"--seed": i += 1; seed = int(String(args[i])) if i < args.size() else seed
			"--size": i += 1; size = int(String(args[i])) if i < args.size() else size
			"--source": i += 1; source_rel = String(args[i]) if i < args.size() else source_rel
		i += 1

	# Resolve the output dir relative to the project root (res://) → an absolute filesystem path.
	var out_abs := ProjectSettings.globalize_path("res://".path_join(out_rel))
	DirAccess.make_dir_recursive_absolute(out_abs)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# Prefer a real source image (richer content → every painterly effect has something to act on and
	# no genome collapses to a flat block). Falls back to the deterministic synthetic gradient.
	var src: Image = null
	if source_rel != "":
		var src_abs := ProjectSettings.globalize_path("res://".path_join(source_rel))
		if FileAccess.file_exists(src_abs):
			var loaded := Image.load_from_file(src_abs)
			if loaded != null:
				# center-crop to a square then resize to `size` so thumbnails are uniform cards
				var w := loaded.get_width()
				var h := loaded.get_height()
				var s := mini(w, h)
				var region := Rect2i((w - s) / 2, (h - s) / 2, s, s)
				var square := loaded.get_region(region)
				square.resize(size, size, Image.INTERPOLATE_LANCZOS)
				square.convert(Image.FORMAT_RGBAF)
				src = square
	if src == null:
		src = PrimRender2D.synthetic_source(size, size)

	var manifest: Array = []
	var all_ok := true
	for k in n:
		# Seed a genome; if its render collapses to a near-flat block (a degenerate look that would show
		# as a solid card), re-draw up to a few times so every gen-0 card is a MEANINGFUL painterly look.
		var eg: EvolverGenome = null
		var img: Image = null
		for _attempt in 8:
			eg = EvolverGenome.random_seed(int(3), 0, rng)   # 3 seed layers (DEFAULT_META.seed_layers)
			img = EffectStackCpu.apply(eg.genome.to_stack(), src)
			if _image_spread(img) >= 0.02:
				break
		var path := out_abs.path_join("%d.png" % k)
		var err := img.save_png(path)
		var ok := err == OK and FileAccess.file_exists(path)
		all_ok = all_ok and ok
		var caption := _stack_caption(eg.to_dict())
		manifest.append({
			"index": k,
			"genome_id": eg.id,
			"origin": eg.to_dict().get("origin", "seed"),
			"caption": caption,
			"file": "%d.png" % k,
			"ok": ok,
			"spread": _image_spread(img),
		})
		print("[render_gen0] %d.png  id=%s  ok=%s  spread=%.3f  look=%s" % [k, eg.id, str(ok), _image_spread(img), caption])

	# Write a manifest so the live-push step reads exact genome ids + captions (id↔card mapping seed).
	var mf := FileAccess.open(out_abs.path_join("manifest.json"), FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify({ "generation": 0, "seed": seed, "size": size, "candidates": manifest }, "\t"))
		mf.close()
	print("[render_gen0] all_ok=%s  out=%s" % [str(all_ok), out_abs])
	quit(0 if all_ok else 1)

## A cheap luminance-spread proxy in [0,1]: max-min mean-channel value over a coarse grid. Near 0 means
## a flat/uniform image (a degenerate look). Used only to reject collapsed genomes at seed time.
func _image_spread(img: Image) -> float:
	if img == null:
		return 0.0
	if img.get_width() < 2 or img.get_height() < 2:
		return 0.0
	# Downsample to a tiny thumb first (fast) then scan that — get_pixel on a full 512² is too slow.
	var t := img.duplicate() as Image
	t.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var lo := 2.0
	var hi := -2.0
	for y in 16:
		for x in 16:
			var c := t.get_pixel(x, y)
			var lum := (c.r + c.g + c.b) / 3.0
			lo = minf(lo, lum)
			hi = maxf(hi, lum)
	return clampf(hi - lo, 0.0, 1.0)

func _stack_caption(genome: Dictionary) -> String:
	var stack: Dictionary = genome.get("stack", {})
	var layers: Array = stack.get("stack", [])
	var names: Array = []
	for l in layers:
		if typeof(l) == TYPE_DICTIONARY:
			names.append(String(l.get("type", "?")))
	return " -> ".join(names) if names.size() > 0 else "(empty look)"
