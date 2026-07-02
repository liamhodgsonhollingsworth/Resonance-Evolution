extends SceneTree
## MATERIAL APPLICATION EXAMPLE — one evolved procedural texture applied to a SANDBOX BUILDING-BLOCK
## mesh. This is the proof-of-seam for the untextured-blocks arc: sandbox_creative.gd's BlockRecord
## carries a `material` slot as DATA (the live-texturing seam), and this example shows the exact
## genome → PNG → ImageTexture → StandardMaterial3D → block-mesh path a texturing system drives
## through that seam. It deliberately does NOT build the live-texturing node system (a separate
## owned arc) — it only demonstrates that a TextureGenome's output is directly usable as a block
## material, headless-provably.
##
## Run:
##   godot --headless --path godot -s res://examples/texture_block_material.gd
## Writes the 256px tile to user://evolver/textures/example_block_tile.png and prints PASS/FAIL.

func _initialize() -> void:
	var ok := true

	# 1. A deterministic texture genome (fixed seed → the same tile every run).
	var rng := RandomNumberGenerator.new()
	rng.seed = 626
	var genome := TextureGenome.random(3, rng)
	ok = _check("genome is valid", genome.is_valid()) and ok

	# 2. Genome → 256px tile (the CPU synthesis delegate).
	var tile := TextureSynthCpu.synthesize(genome.to_stack(), 256, 256)
	ok = _check("tile synthesized at 256x256", tile.get_width() == 256 and tile.get_height() == 256) and ok
	var out_dir := ProjectSettings.globalize_path("user://evolver/textures")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var png_path := out_dir.path_join("example_block_tile.png")
	ok = _check("tile saved to PNG", tile.save_png(png_path) == OK and FileAccess.file_exists(png_path)) and ok

	# 3. Tile → material → SANDBOX BLOCK MESH. The mesh is the sandbox "Cube" block verbatim
	#    (GodotSceneRenderer._primitive_mesh, the same call sandbox_creative.gd's _set_block makes),
	#    so what is proven here is exactly what a block in the creative sandbox would show.
	var mesh := GodotSceneRenderer._primitive_mesh("box", { "width": 1.0, "height": 1.0, "depth": 1.0 })
	ok = _check("sandbox block mesh built (box 1x1x1)", mesh != null) and ok
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(tile)
	var block := MeshInstance3D.new()
	block.mesh = mesh
	block.material_override = mat
	root.add_child(block)
	ok = _check("block carries the generated texture as its albedo",
		block.material_override is StandardMaterial3D
		and (block.material_override as StandardMaterial3D).albedo_texture != null
		and (block.material_override as StandardMaterial3D).albedo_texture.get_width() == 256) and ok

	print("tile: ", png_path)
	print("genome: ", JSON.stringify(genome.to_stack()))
	print("RESULT: ", "ALL PASS" if ok else "FAIL")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
