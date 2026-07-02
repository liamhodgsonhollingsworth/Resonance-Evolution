class_name PainterlyFalloff
extends RefCounted
## The PAINTERLY applier that VARIES BY THE DETAIL FIELD — the first concrete instantiation of Liam's
## generic-detail-falloff spec (project-generic-detail-falloff-2026-07-01). It paints a source frame so
## that the brush strokes CHANGE with the local detail: more/finer strokes where the DetailField is
## high, fewer/coarser strokes where it is low. The single `detail_knob` + the falloff curve (both DATA,
## consumed via DetailField.build) drive the whole variation — turn the knob and the entire painted
## frame re-budgets; swap the curve and the high-detail region moves.
##
## THE MECHANISM (deliberately simple + algorithm-agnostic, as the spec asks for a "simple first cut"):
##   1. Render the SAME effect stack at TWO detail levels over the source frame, reusing EffectStackCpu
##      verbatim (no pixel math rebuilt): a HIGH-detail pass (the stack's fine painterly params) and a
##      LOW-detail pass (the stack's params scaled toward "coarser": larger Kuwahara radius / fewer
##      posterize levels / heavier grain — the coarse-brush end of each knob).
##   2. Per-pixel BLEND between the two by the detail field d ∈ [0..1]:
##        out(x,y) = lerp(low(x,y), high(x,y), d(x,y))
##      so d≈1 regions get the fine/dense look and d≈0 regions get the coarse/sparse look — the brush
##      density/fineness VARIES with the local detail exactly as specified. Two passes + a field-blend is
##      the minimal thing that makes "strokes change by the detail" TRUE and visible; a later delegate
##      can do a true per-pixel-radius Kuwahara against this SAME field without changing the seam.
##
## WHY blend-of-two-passes and not per-pixel-radius directly: it keeps the FIRST cut trivial + provably
## correct (each pass is the proven CPU oracle) while making the field load-bearing — the field is what
## the follow-on (a genuinely variable-radius kernel driven by d) plugs into, with zero caller change.
## This is the "do as little as possible; build the seam" law: the detail FIELD is the durable seam,
## the two-pass blend is the placeholder algorithm behind it.
##
## Everything is DATA in (source Image + effect_stack descriptor + knob + falloff curve) → a NEW Image
## out (source untouched). No shader, no GPU, headless — the CPU reference the same way EffectStackCpu is.

## Paint `src` with `stack`, VARYING the painterly detail across the frame by a DetailField built from
## `detail_knob` + `falloff`. Returns a NEW Image. `coarsen` (0..1, default 1) sets how much the
## low-detail pass is coarsened relative to the high pass (0 = both passes identical → uniform look,
## the field has no visible effect; 1 = maximally coarse periphery). The one entry point.
static func paint(src: Image, stack: Dictionary, detail_knob: float, falloff: Dictionary, coarsen: float = 1.0) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var field := DetailField.build(w, h, detail_knob, falloff)
	# The high-detail pass = the stack as authored (fine params). The low-detail pass = the stack with
	# each layer's params pushed toward "coarser" — the field then chooses between them per pixel.
	var high := EffectStackCpu.apply(stack, src)
	var low := EffectStackCpu.apply(coarsen_stack(stack, clampf(coarsen, 0.0, 1.0)), src)
	var out := Image.create(w, h, false, src.get_format())
	var i := 0
	for y in h:
		for x in w:
			var d := field[i] if i < field.size() else 0.0
			var hc := high.get_pixel(x, y)
			var lc := low.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				lerpf(lc.r, hc.r, d),
				lerpf(lc.g, hc.g, d),
				lerpf(lc.b, hc.b, d),
				lerpf(lc.a, hc.a, d)
			))
			i += 1
	return out

## Produce a COARSENED copy of an effect_stack: each layer's numeric knobs are pushed toward the
## "coarser / fewer / heavier-brush" end by `amount` ∈ [0..1] (0 = unchanged, 1 = fully coarse). This is
## the low-detail pole of the blend; the semantics per effect (bigger Kuwahara radius = broader strokes,
## fewer posterize levels = flatter, more grain = rougher paper) are what make the periphery read as
## "less detailed painting". Effects with no coarsening knob pass through unchanged. Pure DATA→DATA.
static func coarsen_stack(stack: Dictionary, amount: float) -> Dictionary:
	var out_layers := []
	for layer in stack.get("stack", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var t := String(layer.get("type", "passthrough"))
		var p: Dictionary = (layer.get("params", {}) as Dictionary).duplicate(true)
		match t:
			"kuwahara", "generalized_kuwahara":
				# Bigger radius → broader, coarser brush strokes (fewer, wider flattened regions).
				var r := float(p.get("radius", 2.0))
				p["radius"] = int(round(lerpf(r, r + 3.0, amount)))
			"posterize":
				# Fewer levels → flatter, blockier paint (less tonal detail).
				var lv := float(p.get("levels", 4.0))
				p["levels"] = maxi(2, int(round(lerpf(lv, max(2.0, lv - 2.0), amount))))
			"paper_grain":
				# Slightly more grain → rougher paper in the coarse periphery. GENTLE (×2 of the authored
				# amount, not a flat +0.35): the old +0.35 bump put ±40%+ multiplicative noise over every
				# coarse-dominant region (sky, ground), which read as per-pixel STATIC — the residual
				# "pixelated" look. Coarse painting means BROADER STROKES (the kuwahara radius above), not
				# heavier noise; the grain only nudges up so the periphery paper feels a touch rougher.
				var amt := float(p.get("amount", 0.15))
				p["amount"] = clampf(lerpf(amt, min(1.0, amt * 2.0), amount), 0.0, 1.0)
			"edge_darken":
				# Weaker edge pooling → softer, less-defined contours in the coarse periphery.
				var s := float(p.get("strength", 1.0))
				p["strength"] = max(0.0, lerpf(s, s * 0.4, amount))
			"outline":
				# Higher threshold → fewer ink lines survive → coarser, less-detailed outline.
				var th := float(p.get("threshold", 0.25))
				p["threshold"] = clampf(lerpf(th, min(1.0, th + 0.25), amount), 0.0, 1.0)
			_:
				pass  # effects with no natural "coarseness" knob are carried through unchanged
		out_layers.append({ "type": t, "params": p })
	return { "stack": out_layers }
