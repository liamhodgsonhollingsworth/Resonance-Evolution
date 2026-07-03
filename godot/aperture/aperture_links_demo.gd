extends Control
## APERTURE LINKS DEMO — the live proof of Liam's §1 spec (2026-07-03): the Aperture is for
## rapid iteration, so it has (a) a CHAT you type iteration requests into, and (b) clickable
## cards that open ANOTHER AREA — a separately-constructed 2D or 3D scene in its OWN
## window/process.
##
##   godot --path godot res://aperture/aperture_links_demo.tscn
##
## Left: the embeddable chat panel (same channel as the web composer). Right: two scene-link
## cards — one 3D (the painterly example) and one 2D (the aperture board) — each click spawns
## a separate detached Godot window via ApertureSceneLauncher. The status line shows the
## equivalent resonance:// URL for each card: pushing THAT url on a web card opens the SAME
## window from Firefox, proving web/Godot equivalence.

const CARDS := [
	{
		"title": "Open 3D area — painterly scene",
		"scene_link": {"kind": "scene_link", "scene": "res://examples/painterly_scene.tscn",
			"mode": "3d"},
	},
	{
		"title": "Open 2D area — aperture board",
		"scene_link": {"kind": "scene_link", "scene": "res://aperture/aperture_board.tscn",
			"mode": "2d"},
	},
]

var _status: Label


func _ready() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.split_offset = 420
	add_child(split)

	# Left: the chat panel (the same embeddable Control a board's ChatPanelSlot hosts).
	var chat: Control = load("res://aperture/aperture_chat_panel.tscn").instantiate()
	chat.custom_minimum_size = Vector2(360, 0)
	split.add_child(chat)

	# Right: the scene-link cards.
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	split.add_child(right)
	var head := Label.new()
	head.text = "Click a card — a separate window opens (2D or 3D area)"
	right.add_child(head)
	for card in CARDS:
		var btn := Button.new()
		btn.text = String(card["title"])
		btn.custom_minimum_size = Vector2(0, 44)
		var link: Dictionary = card["scene_link"]
		btn.pressed.connect(func(): _open(link))
		right.add_child(btn)
		var url := Label.new()
		url.text = "web-equivalent: " + ApertureSceneLauncher.to_resonance_url(link)
		url.add_theme_font_size_override("font_size", 10)
		url.modulate = Color(1, 1, 1, 0.55)
		url.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		right.add_child(url)
	_status = Label.new()
	_status.text = "ready"
	right.add_child(_status)


func _open(link: Dictionary) -> void:
	var pid := ApertureSceneLauncher.launch(link)
	_status.text = ("opened pid %d — %s" % [pid, link["scene"]]) if pid > 0 \
		else "launch FAILED for " + String(link["scene"])
