class_name ApertureSceneLauncher
extends RefCounted
## CLICK-TO-OPEN SCENE LINKS — clicking something in the Aperture opens ANOTHER AREA: a
## separately-constructed scene (2D or 3D) in its OWN Godot window/process (Liam verbatim
## 2026-07-03 §1: "I should be able to click something that opens another area ... These can
## be separate windows or processes").
##
## THE SCENE_LINK CONVENTION (shared by BOTH surfaces — this is the data, not the code):
##
##     {
##       "kind": "scene_link",                 # optional marker
##       "scene": "res://examples/x.tscn",     # REQUIRED. res://… or project-relative .tscn/.scn
##       "project_path": "G:/…/godot",         # optional; dir containing project.godot.
##                                             #   default: THIS running project.
##       "mode": "2d" | "3d",                  # optional metadata; forwarded as --mode=<m>
##       "params": { … }                       # optional; forwarded as --scene-params=<json>
##     }
##
## The SAME link opens the SAME window from either surface:
##   * GODOT surface: activating a card/button calls `launch(link)` here → OS.create_process
##     spawns a SEPARATE detached Godot window running that scene (no console popup: the Godot
##     exe is a GUI-subsystem binary; no shell/PowerShell is involved).
##   * WEB surface: the card carries the equivalent `resonance://open?target=godot&scene=…
##     [&mode=…&params=<url-encoded json>&project=…]` link → Windows protocol handler records a
##     launch request → aperture_launch_watcher.py builds the SAME argv and spawns the SAME
##     window. `parse()` below accepts that URL form too, so one link string serves both.
##
## Scene-path SAFETY mirrors the watcher's `_clean_scene` exactly (values are corpus/URL-
## sourced): reject traversal (`..`), drive letters/schemes (`:`), whitespace, and require a
## .tscn/.scn extension. Params are forwarded AFTER Godot's `--` separator so they reach the
## scene via OS.get_cmdline_user_args() without Godot itself interpreting them.


## Normalise a requested scene path to a safe `res://…` reference, or "" if rejected.
## EXACT mirror of aperture_launch_watcher._clean_scene (Wavelet) — keep the two in sync.
static func clean_scene(raw) -> String:
	if typeof(raw) != TYPE_STRING:
		return ""
	var s := String(raw).strip_edges()
	if s == "":
		return ""
	var body := s
	if body.to_lower().begins_with("res://"):
		body = body.substr(6)
	body = body.replace("\\", "/")
	while body.begins_with("/"):
		body = body.substr(1)
	if body == "":
		return ""
	if body.split("/").has(".."):
		return ""
	if body.contains(":"):
		return ""
	for i in body.length():
		var ch := body[i]
		if ch == " " or ch == "\t" or ch == "\n" or ch == "\r":
			return ""
	var low := body.to_lower()
	if not (low.ends_with(".tscn") or low.ends_with(".scn")):
		return ""
	return "res://" + body


## Parse EITHER form of a scene link into one normalized dict:
##   * a Dictionary already shaped like the convention above, or
##   * a `resonance://…` URL string (the web surface's link form, target godot).
## Returns {ok:true, scene, project_path, mode, params} or {ok:false, error}. Never raises.
static func parse(value) -> Dictionary:
	if typeof(value) == TYPE_DICTIONARY:
		return _parse_dict(value)
	if typeof(value) == TYPE_STRING:
		return _parse_url(String(value))
	return {"ok": false, "error": "scene_link must be a Dictionary or a resonance:// string"}


static func _parse_dict(d: Dictionary) -> Dictionary:
	var scene := clean_scene(d.get("scene"))
	if scene == "":
		return {"ok": false, "error": "missing/invalid scene (need res://….tscn)"}
	var project := String(d.get("project_path", d.get("project", "")))
	var mode := String(d.get("mode", "")).to_lower()
	if mode != "" and mode != "2d" and mode != "3d":
		return {"ok": false, "error": "mode must be 2d or 3d"}
	var params = d.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		return {"ok": false, "error": "params must be a Dictionary"}
	return {"ok": true, "scene": scene, "project_path": project, "mode": mode,
		"params": params}


static func _parse_url(url: String) -> Dictionary:
	var raw := url.strip_edges()
	if not raw.to_lower().begins_with("resonance://"):
		return {"ok": false, "error": "not a resonance:// url"}
	var q := {}
	var qpos := raw.find("?")
	var head := raw if qpos < 0 else raw.substr(0, qpos)
	if qpos >= 0:
		for pair in raw.substr(qpos + 1).split("&"):
			var eq := String(pair).find("=")
			if eq <= 0:
				continue
			q[String(pair).substr(0, eq)] = String(pair).substr(eq + 1).uri_decode()
	# target: explicit ?target= wins, else host/path segment (resonance://godot?…). Only the
	# godot target maps to a scene link — a webpage/aperture link is not launchable here.
	var target := String(q.get("target", "")).to_lower()
	if target == "":
		var body := head.substr("resonance://".length())
		for seg in body.split("/"):
			var s := String(seg).to_lower()
			if s == "godot" or s == "webpage" or s == "aperture":
				target = s
				break
		if target == "":
			target = "godot"
	if target != "godot":
		return {"ok": false, "error": "target %s is not a scene link" % target}
	var params = {}
	var params_raw := String(q.get("params", ""))
	if params_raw != "":
		var parsed = JSON.parse_string(params_raw)
		if typeof(parsed) == TYPE_DICTIONARY:
			params = parsed
	return _parse_dict({"scene": q.get("scene", ""), "project_path": q.get("project", ""),
		"mode": q.get("mode", ""), "params": params})


## Build the resonance:// URL for a scene link (the WEB side of the same click). Pushing a
## card whose link is this URL makes the web surface open the identical window.
static func to_resonance_url(link: Dictionary) -> String:
	var p := parse(link)
	if not bool(p.get("ok", false)):
		return ""
	var url := "resonance://open?target=godot&scene=" + String(p["scene"]).uri_encode()
	if String(p["mode"]) != "":
		url += "&mode=" + String(p["mode"])
	if not (p["params"] as Dictionary).is_empty():
		url += "&params=" + JSON.stringify(p["params"]).uri_encode()
	if String(p["project_path"]) != "":
		url += "&project=" + String(p["project_path"]).uri_encode()
	return url


## The argv (WITHOUT the exe) for spawning the linked scene as a separate window. Pure —
## the headless test asserts on this without opening real windows. Mirrors the watcher's
## `_spec_godot`: `--path <project> <res://scene>` (+ `-- --mode=… --scene-params=<json>`).
static func build_args(link: Dictionary) -> PackedStringArray:
	var p := parse(link)
	if not bool(p.get("ok", false)):
		return PackedStringArray()
	var project := String(p["project_path"])
	if project == "":
		project = ProjectSettings.globalize_path("res://")
	project = project.replace("\\", "/").trim_suffix("/")
	var args := PackedStringArray(["--path", project, String(p["scene"])])
	var user_args := PackedStringArray()
	if String(p["mode"]) != "":
		user_args.append("--mode=" + String(p["mode"]))
	if not (p["params"] as Dictionary).is_empty():
		user_args.append("--scene-params=" + JSON.stringify(p["params"]))
	if not user_args.is_empty():
		args.append("--")
		args.append_array(user_args)
	return args


## SPAWN the linked scene as a SEPARATE Godot process/window. Returns the pid, or -1 on a
## rejected link / spawn failure. `exe` defaults to the running Godot binary
## (OS.get_executable_path()) so the spawned window uses the exact same engine build.
## Detached (OS.create_process), GUI-subsystem — no console window is ever created.
static func launch(link, exe: String = "") -> int:
	var p := parse(link)
	if not bool(p.get("ok", false)):
		push_warning("scene_link rejected: " + String(p.get("error", "?")))
		return -1
	if exe == "":
		exe = OS.get_executable_path()
	var args := build_args(p)
	if args.is_empty():
		return -1
	return OS.create_process(exe, args)


## Convenience for boards: launch from a normalized Aperture CARD. Checks, in order:
## card.data.scene_link (dict form), then card.link when it is a resonance:// godot URL.
## Returns pid or -1 (silently, when the card simply has no scene link).
static func launch_card(card: Dictionary, exe: String = "") -> int:
	var data = card.get("data", {})
	if typeof(data) == TYPE_DICTIONARY and typeof(data.get("scene_link")) == TYPE_DICTIONARY:
		return launch(data["scene_link"], exe)
	var link := String(card.get("link", ""))
	if link.to_lower().begins_with("resonance://"):
		return launch(link, exe)
	return -1
