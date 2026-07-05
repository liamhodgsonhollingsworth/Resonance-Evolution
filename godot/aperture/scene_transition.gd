extends RefCounted
## SCENE TRANSITION MANAGER — the 3D-aperture's room-to-room mover (Liam spec 2026-07-05 item 5:
## "the transition between the 2D page and the 3D scenes should, ideally, happen in the same window.
## However, for the experimental scenes that rely on a new system that could break, they should
## instead open a new godot window ... For 3D scene transitions, you should try to make these as
## seamless as possible so that it feels as much like moving between two physical rooms as possible").
##
## ONE per-target FLAG decides the channel, so migrating an experimental scene back to same-window is
## a one-line data edit (`same_window: true`) — the CLEAN SEAM the spec asks for ("Later on, these
## should then be connected back to being in the same 3D window"):
##
##   TARGET (a door's destination, or a 2D-board scene_link):
##     {
##       "scene": "res://examples/x.tscn",   # REQUIRED (res://… .tscn/.scn); validated via ApertureSceneLauncher
##       "same_window": true | false,        # true → change_scene_to_file (SAME process, seamless fade)
##                                           # false → a NEW godot window (ApertureSceneLauncher.launch)
##       "experimental": true,               # convenience: experimental ⇒ same_window defaults to false
##       "project_path": "G:/…/godot",       # optional; only used for the new-window path
##       "mode": "2d"|"3d", "params": {…},   # optional; forwarded to the new-window scene
##       "label": "Explore gallery"          # optional; UI text only
##     }
##
## SAME-WINDOW is `SceneTree.change_scene_to_file` — Godot swaps the whole active scene in the one
## process (no reload flash, no second window). SEAMLESSness is a brief black fade-out on a top
## CanvasLayer, the swap under cover of black, then fade-in — the "step through a doorway" feel. The
## fade is DATA (`fade_seconds`), so it tunes without code.
##
## NEW-WINDOW delegates to the existing, tested ApertureSceneLauncher (scene_launcher.gd) — the exact
## detached-process path the 2D board and the resonance:// web protocol already use, so an
## experimental scene opens the SAME way from every surface.
##
## No class_name (mistake #046): consumers preload() this file by path.

const ApertureSceneLauncher := preload("res://aperture/scene_launcher.gd")

const DEFAULT_FADE := 0.35


## Resolve a target dict to a decision WITHOUT acting — pure, so tests assert on the routing
## without opening windows or swapping scenes. Returns:
##   { ok:true, channel:"same_window"|"new_window", scene, project_path, mode, params, label } or
##   { ok:false, error }.
static func plan(target) -> Dictionary:
	if typeof(target) != TYPE_DICTIONARY:
		return { "ok": false, "error": "target must be a Dictionary" }
	var t: Dictionary = target
	var scene := ApertureSceneLauncher.clean_scene(t.get("scene"))
	if scene == "":
		return { "ok": false, "error": "missing/invalid scene (need res://….tscn)" }
	# The FLAG. Explicit `same_window` wins; otherwise experimental ⇒ new window, stable ⇒ same window.
	var same_window: bool
	if t.has("same_window"):
		same_window = bool(t["same_window"])
	else:
		same_window = not bool(t.get("experimental", false))
	return {
		"ok": true,
		"channel": "same_window" if same_window else "new_window",
		"scene": scene,
		"project_path": String(t.get("project_path", t.get("project", ""))),
		"mode": String(t.get("mode", "")),
		"params": t.get("params", {}) if typeof(t.get("params", {})) == TYPE_DICTIONARY else {},
		"label": String(t.get("label", "")),
		"fade_seconds": float(t.get("fade_seconds", DEFAULT_FADE)),
	}


## The res://scene the SAME-WINDOW channel will change to (or "" if the target routes to a new
## window / is invalid). Lets a caller pre-check whether a target stays in-process.
static func same_window_scene(target) -> String:
	var p := plan(target)
	if bool(p.get("ok", false)) and String(p.get("channel", "")) == "same_window":
		return String(p["scene"])
	return ""


## ENTER a target from a live scene. `host` is any Node inside the running tree (its get_tree()
## drives change_scene / the fade CanvasLayer). Returns the same plan dict, annotated with:
##   result:"changing"  (same-window swap requested; the scene changes after the fade)
##   result:"launched", pid:int  (new window spawned)
##   result:"failed", ... (spawn failed / invalid).
## `exe` overrides the Godot binary for the new-window path (defaults to the running engine).
static func enter(host: Node, target, exe: String = "") -> Dictionary:
	var p := plan(target)
	if not bool(p.get("ok", false)):
		push_warning("scene_transition rejected: " + String(p.get("error", "?")))
		return p
	if String(p["channel"]) == "same_window":
		_same_window_swap(host, p)
		p["result"] = "changing"
		return p
	# new window — the experimental / breakable-system path
	var link := {
		"scene": p["scene"], "project_path": p["project_path"],
		"mode": p["mode"], "params": p["params"],
	}
	var pid := ApertureSceneLauncher.launch(link, exe)
	p["result"] = "launched" if pid > 0 else "failed"
	p["pid"] = pid
	return p


## SEAMLESS same-window swap: fade a top CanvasLayer to black, change the scene under cover of the
## black frame (no reload flash), then the newly-loaded scene fades itself back in when it calls
## fade_in_on_ready (so the room-to-room feel spans the boundary). If a fade cannot be built
## (headless / no tree), it changes the scene immediately — behavior degrades, never breaks.
static func _same_window_swap(host: Node, plan_dict: Dictionary) -> void:
	var scene := String(plan_dict["scene"])
	var tree := host.get_tree() if host != null else null
	if tree == null:
		return
	var fade_seconds := float(plan_dict.get("fade_seconds", DEFAULT_FADE))
	var headless := DisplayServer.get_name() == "headless"
	if headless or fade_seconds <= 0.0:
		tree.change_scene_to_file(scene)
		return
	# Fade cover: a CanvasLayer above everything, on the tree ROOT so it survives the scene change
	# just long enough to hide the swap frame. The next scene removes any leftover cover on ready.
	var layer := CanvasLayer.new()
	layer.name = "__transition_fade"
	layer.layer = 128
	var rect := ColorRect.new()
	rect.color = Color(0, 0, 0, 0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_STOP     # eat input during the fade
	layer.add_child(rect)
	tree.root.add_child(layer)
	var tw := tree.create_tween()
	tw.tween_property(rect, "color:a", 1.0, fade_seconds)
	tw.tween_callback(func():
		tree.change_scene_to_file(scene)
		layer.set_meta("__armed", true))


## Called by a scene in _ready to complete a seamless ENTER: find the leftover black cover the
## transition left on the tree root and fade it out, so the new "room" resolves into view. No-op
## when there is no cover (the scene was opened directly, not via a transition) — safe to call
## unconditionally at the top of every transition-target scene's _ready.
static func fade_in_on_ready(host: Node, fade_seconds: float = DEFAULT_FADE) -> void:
	var tree := host.get_tree() if host != null else null
	if tree == null or DisplayServer.get_name() == "headless":
		return
	var layer := tree.root.get_node_or_null("__transition_fade")
	if layer == null:
		return
	var rect := layer.get_child(0) if layer.get_child_count() > 0 else null
	if rect == null or not (rect is ColorRect):
		layer.queue_free()
		return
	var tw := tree.create_tween()
	tw.tween_property(rect, "color:a", 0.0, fade_seconds)
	tw.tween_callback(layer.queue_free)
