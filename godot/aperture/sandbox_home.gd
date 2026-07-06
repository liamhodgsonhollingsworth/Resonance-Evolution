extends "res://examples/sandbox_creative.gd"
## APERTURE HOME AREA — a sandbox-editable HOME room you reach by walking through a DOOR from the
## current aperture room (Liam 2026-07-06, room-series slice 1). It is the FIRST buildable "home" the
## aperture opens onto: Liam walks through the new door in aperture_3d and can immediately place / move /
## rotate objects, use the palette, and the precise Manipulation Wand to build in it.
##
## WHAT THIS IS — MINIMAL REUSE, NOT A REIMPLEMENTATION (the repo law: "do as little as possible; build
## minimal threads between things that already exist"):
##   * It EXTENDS the creative sandbox controller (examples/sandbox_creative.gd) BY PATH (no class_name —
##     mistake #046: the base preloads its own deps by path; a subclass extending by path inherits them).
##     So EVERY editing capability is inherited verbatim, with zero copy: free placement, pick-up/move,
##     rotate/scale, the block+asset palette, the Manipulation Wand (precise move/rotate), sticky notes,
##     the append-only world store, and the E inventory. Nothing is re-written here.
##   * The ONLY override is _build_env(): the home area gets a SKY + CLOUDS environment via the shared
##     PainterlySky module (renderers/sky.gd + renderers/clouds.gd), honouring the standing directive
##     "3D scenes are ALWAYS iterable with sky + clouds — not a black void". The base sandbox already had
##     a bare procedural sky but NO clouds; this pulls in the reusable cloud layer so the home area reads
##     as an outdoor buildable space and the sky/clouds are themselves data-tunable (the sky module's job).
##   * It uses its OWN world name ("home") so building in the home area saves to its own append-only world
##     versions, separate from the free-standing "starter" sandbox world.
##
## HOW YOU GET HERE: aperture_3d.gd has a door whose target is res://aperture/sandbox_home.tscn (same
## window, seamless). Walk into it; ESC returns to the room (the self-cleaning TransitionOverlay wires
## LEAVE = ESC for every same-window destination, so this scene needs to do nothing for that).
##
## Open live:   <Godot> --path godot res://aperture/sandbox_home.tscn
## Headless:    <Godot> --headless --path godot res://aperture/sandbox_home.tscn -- --bench
## (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe for stdout.)

const PainterlySkyModule := preload("res://renderers/sky.gd")
const SceneTransition := preload("res://aperture/scene_transition.gd")

const HOME_WORLD := "home"


func _ready() -> void:
	# Complete a seamless same-window ENTER if we arrived through a door transition — same call the
	# aperture room makes, so the door's fade resolves into view here too (no-op if opened directly).
	SceneTransition.fade_in_on_ready(self)
	# Build in the home area's OWN append-only world by default (separate from the "starter" sandbox
	# world). The base _ready reads `world_name` when loading, so set it BEFORE calling up.
	world_name = HOME_WORLD
	super._ready()


## OVERRIDE: give the home area a SKY + CLOUDS environment (standing directive — 3D scenes are always
## iterable with sky + clouds, never a black void). Reuses the shared PainterlySky + Clouds modules
## (the same sky the painterly/focus/lsystem scenes use), rather than the base sandbox's bare cloudless
## procedural sky. Pure DATA in -> a live Environment + sun out; nothing else about the sandbox changes.
func _build_env() -> void:
	var built: Dictionary = PainterlySkyModule.build(PainterlySkyModule.default_descriptor())
	var env_node := WorldEnvironment.new()
	env_node.environment = built["environment"]
	add_child(env_node)
	var sun = built["sun"]
	if sun != null:
		add_child(sun)
	# A subtle ground plate so the build has a floor reference (mirrors the base sandbox floor — an
	# outdoor buildable ground, NOT itself a placeable block).
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(80, 80)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.34, 0.42, 0.30)
	fmat.roughness = 0.95
	floor_mi.material_override = fmat
	floor_mi.position = Vector3(0, -0.5 * grid_size, 0)
	add_child(floor_mi)
