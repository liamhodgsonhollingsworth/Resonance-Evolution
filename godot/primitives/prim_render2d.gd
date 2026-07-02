class_name PrimRender2D
extends Primitive
## The RENDER node — turns each genome of a `population` into a real PNG THUMBNAIL by applying its
## effect stack (EffectGenome → EffectStackCpu) over a FIXED demo source image. This is the genome→image
## delegate of the evolver loop: the candidate the human judges is a rendered picture, not a parameter
## vector, so the look is what gets selected (the look IS the phenotype).
##
## It REUSES EffectStackCpu.apply verbatim (the proven CPU oracle) — no pixel math is reimplemented
## here; the node only orchestrates "for each genome, apply its stack to the source, save a PNG". The
## source is a deterministic synthetic gradient (so the test needs no asset and the path is headless),
## overridable via params.source_path (a res:// or user:// image) for the live surface.
##
## The descriptor it emits — `rendered` — pairs each genome with the on-disk thumbnail it produced:
##   { "rendered": [ { "genome": <EvolverGenome.to_dict()>, "image_path": String, "ok": bool }, ... ],
##     "generation": int, "meta_genome": {...} }
## so the next node (ApertureSurface) has both the image to show AND the genome to map the card id back
## to. Pure: it writes PNGs to params.out_dir (a gitignored state path) and returns paths; no Godot
## Image on the wire (portability invariant).
##
## params:
##   out_dir      — where thumbnails are written (default the gitignored evolver state dir).
##   source_path  — optional source image (res://…/user://…); default = a synthetic gradient.
##   width/height — synthetic source size when no source_path (default 64×64; thumbnails are small).

const DEFAULT_OUT := "user://evolver/painterly/thumbs"
const DEFAULT_W := 64
const DEFAULT_H := 64

func _init() -> void:
	prim_type = "Render2D"

func input_ports() -> Array:
	return [{ "name": "population", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "rendered", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var pop_desc = inputs.get("population")
	if not PrimEvolverPopulation.is_population(pop_desc):
		return { "rendered": { "rendered": [], "generation": 0, "meta_genome": {} } }
	var out_dir := String(params.get("out_dir", DEFAULT_OUT))
	_ensure_dir(out_dir)
	var src := _source_image()
	var generation := int(pop_desc.get("generation", 0))
	var rendered: Array = []
	for gd in pop_desc.get("population", []):
		if typeof(gd) != TYPE_DICTIONARY:
			continue
		var eg := EvolverGenome.from_dict(gd)
		# GENOME-KIND dispatch: a texture genome GENERATES its tile (TextureSynthCpu — no source
		# image; the genome is the whole construction); an effect genome POST-PROCESSES the source
		# (EffectStackCpu). Same node, same descriptor, two render delegates.
		var img: Image
		if eg.kind() == "texture":
			img = TextureSynthCpu.synthesize(eg.genome.to_stack(), src.get_width(), src.get_height())
		else:
			img = EffectStackCpu.apply(eg.genome.to_stack(), src)
		var path := out_dir.path_join("g%d_%s.png" % [generation, eg.id])
		var save_err := img.save_png(path)
		rendered.append({
			"genome": eg.to_dict(),
			"image_path": path,
			"ok": save_err == OK and FileAccess.file_exists(path),
		})
	return { "rendered": {
		"rendered": rendered,
		"generation": generation,
		"meta_genome": pop_desc.get("meta_genome", {}),
	} }

## Render ONE genome to a PNG at an explicit path (the CLI tick reuses this without an arrangement).
## Returns true on a written, non-empty PNG. Static so a driver can call it directly. Kind-dispatched
## exactly like evaluate(): texture genomes synthesize at the source's size, effect genomes apply over it.
static func render_genome_to(eg: EvolverGenome, abs_path: String, src: Image) -> bool:
	var img: Image
	if eg.kind() == "texture":
		img = TextureSynthCpu.synthesize(eg.genome.to_stack(), src.get_width(), src.get_height())
	else:
		img = EffectStackCpu.apply(eg.genome.to_stack(), src)
	var err := img.save_png(abs_path)
	return err == OK and FileAccess.file_exists(abs_path)

## A deterministic synthetic source if no source_path is set — a diagonal RGB gradient with a couple of
## hard edges, so EVERY painterly effect (smoothing, posterize, edge-darken, outline, grain, relief) has
## something to act on and the thumbnails are visibly distinct. No asset, fully headless.
func _source_image() -> Image:
	var sp := String(params.get("source_path", ""))
	if sp != "" and FileAccess.file_exists(sp):
		var loaded := Image.load_from_file(sp)
		if loaded != null:
			loaded.convert(Image.FORMAT_RGBAF)
			return loaded
	var w := int(params.get("width", DEFAULT_W))
	var h := int(params.get("height", DEFAULT_H))
	return PrimRender2D.synthetic_source(w, h)

## The deterministic synthetic source, exposed static so the test + CLI build the SAME image the node
## does. A smooth diagonal gradient (gives the smoothers + relief gradients) crossed by a few sharp
## bands (gives the edge/outline effects real edges).
static func synthetic_source(w: int, h: int) -> Image:
	w = maxi(2, w)
	h = maxi(2, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	for y in h:
		for x in w:
			var fx := float(x) / float(w - 1)
			var fy := float(y) / float(h - 1)
			# Smooth diagonal gradient.
			var r := fx
			var g := fy
			var b := (fx + fy) * 0.5
			# A few hard bands so neighbourhood/edge effects have edges to find.
			if (x / maxi(1, w / 4)) % 2 == 0:
				b = clampf(b + 0.4, 0.0, 1.0)
			img.set_pixel(x, y, Color(r, g, b, 1.0))
	return img

func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs)
