extends RefCounted
## UiActions — the ui.*/dialogue.* OP FAMILY for in-world UI (Dreams-arc Slice 5, the interaction demo).
##
## The interaction-authoring format is Source -> BRAIN(Logic) -> Action. Slice 7 shipped the ACTION half
## for real devices (device.*); this ships the ACTION half for in-game UI: a button press shows a
## dialogue, walking into an area opens a menu. Like device.*, every op returns a DECLARATIVE receipt
## (DATA) — the op does NOT draw anything itself; a HOST renders the receipt. In this engine a small
## in-world UI renderer (aperture/ui_action_renderer.gd) is that host; a website / phone renders the same
## receipt with its own widgets. The engine only ever produces serialisable DATA — the portability keystone.
##
## THE CONTRACT (inherited verbatim from WorldActions, runtime/world_actions.gd):
##   • Every op returns a receipt dict ({ ok:true, op:"dialogue.show", speaker, text, ... }), exactly like
##     WorldActions' own set_param and DeviceActions' device.set_led. A host that can render UI honours it
##     (draws the box); a host that cannot still no-ops via WorldActions' "unknown op = declared no-op" path.
##     That is what lets the SAME button->dialogue arrangement run in the game, on a website, and on a phone.
##   • OPT-IN by design. These ops are NOT baked into WorldActions._register_builtins — a host with no UI
##     surface stays SILENT. A host that HAS a UI surface calls register_ui_ops(world_actions) at boot;
##     everything else keeps flowing through the unknown-op no-op. "add a world effect == register one op."
##
## THE OP SET (Slice 5 — the minimal UI catalog; no auto-generalisation beyond the interaction demo):
##   • dialogue.show{speaker, text}   — show a dialogue box (a speaker line + body text).
##   • dialogue.hide{}                — dismiss the dialogue box.
##   • ui.menu.open{title, items}     — open a menu (a title + a list of clickable item labels).
##   • ui.menu.close{}                — close the menu.
##
## Portability: no Godot Node/scene types in the public surface — only Dictionaries + Strings + a plain
## Callable. A GDScript ≡ Python ≡ JS re-implementation only has to match each op's receipt dict shape.

const WorldActions := preload("res://runtime/world_actions.gd")


## Register the ui.*/dialogue.* op family onto a WorldActions op registry (the whole extension surface — a
## new world effect is one register() call, never an engine edit). `world_actions` is a WorldActions
## instance (or anything exposing register(op, fn)). Returns the sorted list of op names it registered, so
## a host / test can confirm the boot step ran. Idempotent: registering again just replaces the same handlers.
##
## HOST-WIDE variant: register_ui_ops(WorldActions) — passing the CLASS instead of an instance — routes
## through WorldActions' static host-op seam (register_host), so every fresh WorldActions a PrimWorldAction
## builds per-evaluate inherits the ops. That is the "a host registers its ui.* at boot" model: the room
## boots once, and thereafter every WorldAction node in every arrangement honours dialogue.show. The
## builtin-shadow guard in register_host makes this safe — a ui.* name can never mask log/set_param/noop.
static func register_ui_ops(world_actions) -> Array:
	if world_actions == null:
		return []
	# The CLASS itself (host-wide static seam) — the boot path the room takes so PrimWorldAction picks it up.
	if world_actions == WorldActions:
		WorldActions.register_host("dialogue.show", _op_dialogue_show)
		WorldActions.register_host("dialogue.hide", _op_dialogue_hide)
		WorldActions.register_host("ui.menu.open", _op_menu_open)
		WorldActions.register_host("ui.menu.close", _op_menu_close)
	else:
		# A concrete instance (a test / a scoped registry): register directly onto it.
		world_actions.register("dialogue.show", _op_dialogue_show)
		world_actions.register("dialogue.hide", _op_dialogue_hide)
		world_actions.register("ui.menu.open", _op_menu_open)
		world_actions.register("ui.menu.close", _op_menu_close)
	return ["dialogue.hide", "dialogue.show", "ui.menu.close", "ui.menu.open"]


## Un-register the ui.*/dialogue.* family from the host-wide static seam. Lets a host / test return to the
## "no UI surface -> unknown op -> declared no-op" baseline (the universality half of the loop test). No-op
## on a host that never registered. Symmetric with register_ui_ops so the boot step is reversible.
static func unregister_ui_ops_host() -> void:
	for op in ["dialogue.show", "dialogue.hide", "ui.menu.open", "ui.menu.close"]:
		WorldActions.unregister_host(op)


# --- the ui.*/dialogue.* ops -----------------------------------------------------------------------
# Each returns a DECLARATIVE receipt. Args arrive merged (node params + wired inputs); we read the named
# keys, coerce to the right shape, and echo them back so a host renders the receipt. str() (never String())
# stringifies a Variant id/target — String() as a constructor throws on a bare number.

## dialogue.show: show a dialogue box. args: { speaker, text }.
## The text commonly rides the single wired `value` port (PrimWorldAction wires op/value/target/key, not
## speaker/text) — so text ALSO reads from a wired `value` payload: a plain string BECOMES the text, or a
## { speaker, text } dict supplies both — with any explicit top-level speaker/text arg overriding it. This
## keeps WorldAction node-not-edit: the dialogue content rides the existing `value` seam, no new port.
static func _op_dialogue_show(args: Dictionary) -> Dictionary:
	var payload = args.get("value", null)
	var pspeaker := ""
	var ptext := ""
	if typeof(payload) == TYPE_DICTIONARY:
		pspeaker = str(payload.get("speaker", ""))
		ptext = str(payload.get("text", ""))
	elif payload != null:
		ptext = str(payload)   # a bare wired string is the dialogue body
	return {
		"ok": true, "op": "dialogue.show",
		"speaker": str(args.get("speaker", pspeaker)),
		"text": str(args.get("text", ptext)),
	}


## dialogue.hide: dismiss the dialogue box. No args needed; a well-formed receipt a host acts on.
static func _op_dialogue_hide(_args: Dictionary) -> Dictionary:
	return { "ok": true, "op": "dialogue.hide" }


## ui.menu.open: open a menu. args: { title, items }. items is a list of clickable labels (any wired
## Array; a single non-array value is wrapped so a scalar still opens a one-item menu). Like dialogue.show,
## title/items also ride the single wired `value` payload: a { title, items } dict supplies both, or a bare
## Array becomes the items — with explicit top-level title/items overriding. Node-not-edit on the value seam.
static func _op_menu_open(args: Dictionary) -> Dictionary:
	var payload = args.get("value", null)
	var ptitle := ""
	var pitems: Array = []
	if typeof(payload) == TYPE_DICTIONARY:
		ptitle = str(payload.get("title", ""))
		pitems = _as_items(payload.get("items", []))
	elif typeof(payload) == TYPE_ARRAY:
		pitems = _as_items(payload)
	return {
		"ok": true, "op": "ui.menu.open",
		"title": str(args.get("title", ptitle)),
		"items": _as_items(args.get("items", pitems)),
	}


## ui.menu.close: close the menu. No args needed; a well-formed receipt a host acts on.
static func _op_menu_close(_args: Dictionary) -> Dictionary:
	return { "ok": true, "op": "ui.menu.close" }


# --- helpers ---------------------------------------------------------------------------------------

## Coerce a wired Variant into a list of string item labels, defensively — malformed args must no-op
## GRACEFULLY (never crash). An Array becomes str()'d entries; a bare scalar wraps into a one-item list;
## null / empty becomes []. (A dict is treated as no items — a menu's items are an ordered list, not a map.)
static func _as_items(v) -> Array:
	var out: Array = []
	match typeof(v):
		TYPE_ARRAY:
			for e in v:
				out.append(str(e))
		TYPE_NIL:
			pass
		TYPE_DICTIONARY:
			pass
		_:
			if str(v) != "":
				out.append(str(v))
	return out
