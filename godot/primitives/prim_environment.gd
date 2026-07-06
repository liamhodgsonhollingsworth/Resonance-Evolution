class_name PrimEnvironment
extends Primitive
## Emits a renderer-NEUTRAL environment/sky descriptor on the `environment` port — as DATA, never a
## live Godot Environment/Sky. The actual Environment + Sky + sun DirectionalLight3D build happens in
## the renderer delegate (GodotSceneRenderer.apply_environment), so the sky is portable to any renderer
## and the SAME descriptor drives a three.js scene.environment / a glTF KHR_lights_punctual sun exactly
## as the Model/Transform/Group/View arrangements already are.
##
## This is the substrate-independence law applied to the SKY: the always-on iterable sky (Liam's
## 2026-07-01 standing rule "3D scenes should always have a sky I can iterate on") stops being a
## host-side sibling config block (painterly_scene._build_env / lsystem_scene._build_env) and becomes
## a NODE on a wire. Change the arrangement's environment params -> the sky diff-hotloads with the rest
## of the scene.
##
## The descriptor is exactly the `sky` descriptor PainterlySky consumes (PainterlySky.default_descriptor):
##   { top_color:[r,g,b], horizon_color:[r,g,b], ground_color:[r,g,b], sun_color:[r,g,b],
##     sun_angle_deg:<f>, sun_azimuth_deg:<f>, sun_energy:<f>, sky_energy:<f>, ambient_energy:<f>,
##     clouds:{...} }
## plus a `kind:"sky"` tag so the renderer can distinguish it from other environment shapes later.
## Renderer-neutral: colors are [r,g,b] arrays, angles are degrees — no Godot object on the wire.
##
## params: any subset of the sky keys above. Unspecified keys fall back to PainterlySky's warm-daytime
##          defaults, so an empty-params Environment node still emits a complete, valid sky.

func _init() -> void:
	prim_type = "Environment"

func output_ports() -> Array:
	return [{ "name": "environment", "type": "environment" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	# Start from the canonical default sky descriptor (single source of truth), then overlay any
	# params the arrangement set. Append-only: build a fresh dict, never mutate the default or params.
	var desc: Dictionary = PainterlySky.default_descriptor().duplicate(true)
	for k in params.keys():
		desc[k] = params[k]
	# Tag the shape so the delegate (and a future non-sky environment type) can dispatch on it.
	desc["kind"] = String(params.get("kind", "sky"))
	return { "environment": desc }
