class_name PrimEffectStack
extends Primitive
## Emits a renderer-NEUTRAL `effect_stack` descriptor — an ORDERED list of post-process effect
## layers, as DATA, never a live Godot shader / CompositorEffect. This is the 2D-image analogue of
## what PrimModel does for 3D geometry: the painterly look is an ARRANGEMENT (which effects, in what
## order, with what knobs), carried on a wire as a plain serializable dict, so the SAME stack can
## drive a Godot Compositor delegate, a three.js postprocessing delegate, or the CPU reference
## applier (EffectStackCpu) unchanged. The renderer is swappable; the look is portable.
##
## This realizes PROGRESS.md item #1 ("Render/effect stack as reorderable arrangement DATA") as the
## evolvable composition seam: `params.layers` is exactly the genome the evolver mutates (reorder a
## layer, tweak a uniform, add/drop an effect → a new look), and a layer is content-addressable, so
## the look composes with the abstract/precompute cache the same way a behavior graph does.
##
## A `effect_stack` descriptor is:
##   { "stack": [ { "type": String, "params": { ... } }, ... ] }
## where each entry names one effect (e.g. "posterize", "passthrough") and its knobs. The DELEGATE
## (per renderer) owns the actual pixel math / shader; this primitive owns only the arrangement.
##
## params.layers = Array of { "type": String, "params": Dictionary } — the ordered effect list.
##   (Order IS the composition: layer[0] runs first. Reordering is a different look = a different
##    genome, which is the whole point of effect-stack-as-DATA.)
##
## NOTHING here is Godot-, shader-, or GPU-specific. Normal-mapping / lighting / temporal-coherence
## effects are LATER layers: each arrives as a new effect `type` a delegate learns to apply, never an
## edit to this primitive (the no-auto-generalization seam — same shape PrimModel holds for meshes).

func _init() -> void:
	prim_type = "EffectStack"

func input_ports() -> Array:
	# An optional upstream image (or another effect_stack to CHAIN onto). Unconnected -> the stack
	# describes a look to be applied to whatever the delegate hands it (the source frame).
	return [{ "name": "in", "type": "image" }]

func output_ports() -> Array:
	# The renderer-neutral effect_stack descriptor. Typed "image" so it wires into image sinks /
	# downstream stacks; the value is DATA (the stack), resolved to pixels only at the delegate.
	return [{ "name": "stack", "type": "image" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var layers := []
	for layer in params.get("layers", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		# Copy each layer to a clean serializable dict (no hidden refs on the wire — the portability
		# invariant every primitive holds). A layer carries its effect type + its knobs, nothing else.
		layers.append({
			"type": String(layer.get("type", "passthrough")),
			"params": (layer.get("params", {}) as Dictionary).duplicate(true)
		})
	var desc := { "stack": layers }
	# CHAINING: if an upstream effect_stack is wired in, prepend its layers so a downstream stack
	# composes ON TOP of the upstream one (upstream runs first). Plain image inputs pass through as a
	# `source` hint for the delegate. Both keep the descriptor pure DATA.
	var upstream = inputs.get("in")
	if typeof(upstream) == TYPE_DICTIONARY and upstream.has("stack"):
		var combined := (upstream["stack"] as Array).duplicate(true)
		combined.append_array(layers)
		desc["stack"] = combined
	elif upstream != null:
		desc["source"] = upstream
	return { "stack": desc }

## Whether a value on a wire is an effect_stack descriptor (the delegate's structural test, mirroring
## GodotSceneRenderer.is_scene_node — duck-typed on the shape, no class coupling).
static func is_effect_stack(v) -> bool:
	return typeof(v) == TYPE_DICTIONARY and v.has("stack") and typeof(v["stack"]) == TYPE_ARRAY
