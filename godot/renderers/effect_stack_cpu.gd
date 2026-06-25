class_name EffectStackCpu
extends RefCounted
## The CPU REFERENCE applier for an `effect_stack` descriptor — the 2D analogue of
## GodotSceneRenderer (the 3D delegate). It consumes a renderer-neutral effect_stack (pure DATA,
## emitted by PrimEffectStack) plus a source Image, and returns a NEW Image with the stack's layers
## applied IN ORDER. It is deliberately renderer-neutral and dependency-free: plain CPU pixel math on
## a Godot `Image`, no shaders, no GPU, no Compositor — so it runs HEADLESS and serves as the
## ground-truth oracle a GPU/shader delegate (Godot CompositorEffect / three.js postprocessing) must
## match, exactly like the glTF exporter is the oracle for the 3D renderer.
##
## WHY a CPU reference first: the look lives in the DATA, so the FIRST iterable increment only needs
## *an* applier that proves order + knobs are honoured. The fast GPU path is a swappable delegate
## added LATER against this same descriptor — no caller change (PROGRESS.md "thin swappable delegates").
##
## EFFECT REGISTRY (this is where new painterly layers land — each a new branch here + its GPU twin,
## never an edit to the primitive):
##   "passthrough"           — identity (the no-op floor; proves ordering is observable).
##   "posterize"             — palette quantization: snap each RGB channel to `levels` bands. The
##                             simplest painterly primitive and the same color-reduction Apeiron's
##                             PainterlyPostProcessor bakes in (color = quantize). params.levels:int>=2.
##   LATER (deferred layers): "kuwahara"/"generalized_kuwahara" (smoothing→brush-strokes),
##                            "watercolor", "edge_darken" (Apeiron's ID-edge outline), "paper_grain",
##                            "blur"/"outline"/"pixelate". Then normal-mapping + lighting + temporal
##                            coherence as their OWN later layers (require depth/normal/motion channels
##                            the source frame doesn't yet carry — explicitly out of THIS increment).

## Apply an effect_stack descriptor to a source Image, returning a NEW Image (source untouched).
## Unknown effect types are skipped with a warning (forward-compatible: a descriptor authored against
## a richer delegate still runs the layers THIS applier understands, the rest are no-ops here).
static func apply(desc: Dictionary, src: Image) -> Image:
	var img := src.duplicate() as Image
	for layer in desc.get("stack", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		match String(layer.get("type", "passthrough")):
			"passthrough":
				pass
			"posterize":
				_posterize(img, layer.get("params", {}))
			_:
				push_warning("EffectStackCpu: unknown effect '%s' (skipped)" % layer.get("type"))
	return img

## Palette quantization: each channel snapped to one of `levels` evenly-spaced bands. levels=2 →
## hard 2-tone per channel; higher levels → smoother. Pure per-pixel function (no neighbourhood), so
## it is order-independent of itself and trivially correct to verify. Mutates `img` in place.
static func _posterize(img: Image, params: Dictionary) -> void:
	var levels := int(params.get("levels", 4))
	if levels < 2:
		levels = 2
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(
				_quantize(c.r, levels),
				_quantize(c.g, levels),
				_quantize(c.b, levels),
				c.a
			))

## Snap a [0,1] value to the nearest of `levels` evenly-spaced bands at 0, 1/(L-1), ..., 1. So a
## channel value is reduced to one of L discrete tones — the defining operation of posterization.
static func _quantize(v: float, levels: int) -> float:
	var steps := float(levels - 1)
	return round(clampf(v, 0.0, 1.0) * steps) / steps
