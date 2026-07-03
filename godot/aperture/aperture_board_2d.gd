class_name ApertureBoard2D
extends Control
## The 2D GODOT APERTURE BOARD — a Control-node DUPLICATE of the web Aperture board (Liam
## 2026-07-03, card apx_11a5dce2: "an equivalent system that functioned the exact same between
## the two renderers (web and godot), and was as similar as possible, to prove that the system
## neutrality was being followed"). NOT the 3D room (aperture_3d.tscn stays, append-only; THIS
## scene is the corrected primary Godot aperture surface).
##
## Same substrate, same regions, same behavior as static/aperture/index.html + aperture.js:
##   • chat slot        — ChatPanelSlot placeholder (peer lane builds the chat panel; see below)
##   • notifications    — full-width, never-clipped top rows (gold left rule), decision buttons
##   • evolver entry    — ONE compact "Evolution — N candidates" tile linking the evolution page
##   • bento grid       — masonry columns of tiles: image (same sources the web loads, via the
##                        media-route reverse-map or http), title, subtitle, summary, hover
##                        ✕ skip (durable, same feedback.jsonl set the web reads) + ☆ bookmark
##   • Ctrl+Z           — undo the last skip (writes the same "unskip" the web writes)
##   • 10s poll         — notifications/evolver refresh live; the content grid stays FROZEN
##                        between user closes (web Bug-2 static-ordering parity)
## Routing/ordering is ApertureBoardLogic (line-for-line aperture.js port); reads/writes are the
## shared ApertureInbox/ApertureActions substrate helpers (http with file fallback).
##
## Known, documented differences from the web renderer (Godot-theme limits, all cosmetic):
##   • masonry packing is greedy shortest-column (CSS multi-column balances slightly differently)
##   • fonts are Godot's default sans (no Georgia serif); sizes/colors mirror aperture.css
##   • no right-click history grid yet (the web's archive history view) — skip/undo are complete
##
## Run windowed:            godot --path godot res://aperture/aperture_board_2d.tscn
## One-shot screenshot:     godot --path godot res://aperture/aperture_board_2d.tscn -- --shot
## File-mode fixture:       ... -- --mode file --inbox <p> --feedback <p> --bookmarks <p>

# ---- palette: aperture.css :root, colors referenced by handle (relinkable) -----------------------
const COL_BG := Color("000000")
const COL_INK := Color("d8d8d8")
const COL_INK_STRONG := Color("f4f4f4")
const COL_INK_SOFT := Color("9aa7b8")
const COL_INK_FAINT := Color("5a6472")
const COL_LINK := Color("6ba3d6")
const COL_CARD_BG := Color(10 / 255.0, 12 / 255.0, 18 / 255.0, 0.96)
const COL_CARD_BORDER := Color(107 / 255.0, 163 / 255.0, 214 / 255.0, 0.28)
const COL_CARD_BORDER_HOVER := Color(143 / 255.0, 188 / 255.0, 228 / 255.0, 0.65)
const COL_IMG_BG := Color("0a0c12")
const COL_BTN_BG := Color(3 / 255.0, 5 / 255.0, 9 / 255.0, 0.7)
const PALETTE := {
	"accent.cool": Color("6ba3d6"), "accent.warm": Color("d68f6b"), "accent.gold": Color("d6be6b"),
	"accent.violet": Color("a98fd6"), "accent.green": Color("7fc6a3"), "accent.pink": Color("e7b3bb"),
	"accent.red": Color("e0564f"),
}
const GAP := 12                     # --gap
const MAX_WIDTH := 1400             # .bento max-width
const CAROUSEL_INTERVAL := 4.0      # CAROUSEL_INTERVAL_MS
const POLL_INTERVAL := 10.0         # POLL_INTERVAL_MS

## config (all DATA; user-args can override):
##   mode           "auto" (http, file fallback) | "http" | "file"
##   base_url       the web board's server origin
##   inbox_path/feedback_path/bookmarks_path   file-mode substrate paths
##   board_json_path                           the curated board json (file mode)
var config: Dictionary = {
	"mode": "auto",
	"base_url": "http://127.0.0.1:8770",
	"inbox_path": "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl",
	"feedback_path": "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl",
	"bookmarks_path": "G:/Wavelet/Alethea-cc/state/aperture/bookmarks.jsonl",
	"board_json_path": "G:/Wavelet/repos/Resonance-Website/static/aperture/aperture_board.json",
}

var _scroll: ScrollContainer
var _margin: MarginContainer
var _root_vbox: VBoxContainer
var chat_panel_slot: MarginContainer          # ChatPanelSlot — the peer chat panel's embed point
var _notif_row: VBoxContainer
var _evolver_row: VBoxContainer
var _masonry: HBoxContainer
var _columns: Array = []                      # VBoxContainer per masonry column
var _col_heights: Array = []                  # greedy-masonry accumulated estimates

var _skipped: Dictionary = {}                 # optimistic local skip set (skip_id -> true)
var _bookmarked: Dictionary = {}              # session bookmark set (dom tile_id -> true)
var _displayed: Dictionary = {}               # card id -> tile node currently in the grid
var _queue: Array = []                        # last fetched content cards (the refill queue)
var _last_compose: Dictionary = {}            # the latest compose() result (tests read this)
var _last_notif_key := ""
var _last_evolver_key := ""
var _mode_in_use := ""                        # "http" | "file" after the first successful fetch
var _last_archive: Dictionary = {}            # Ctrl+Z state: {card, col, idx, refill}
var _carousels: Array = []                    # [{rect, textures, dots, idx, tile}]
var _img_queue: Array = []                    # pending http image loads
var _img_workers := 0
const IMG_WORKERS_MAX := 3
var _board_cards_cache: Array = []
var _board_json_loaded := false
var _shot_requested := false
var _shot_out := "res://live/aperture_board_2d.png"

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_parse_user_args()
	_build_ui()
	resized.connect(_on_resized)
	var t := Timer.new()
	t.wait_time = POLL_INTERVAL
	t.timeout.connect(_poll)
	add_child(t)
	t.start()
	var ct := Timer.new()
	ct.wait_time = CAROUSEL_INTERVAL
	ct.timeout.connect(_advance_carousels)
	add_child(ct)
	ct.start()
	await refresh()
	if _shot_requested:
		await _capture_shot(_shot_out)
		get_tree().quit()

func _parse_user_args() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a: String = args[i]
		match a:
			"--shot":
				_shot_requested = true
				if i + 1 < args.size() and not String(args[i + 1]).begins_with("--"):
					_shot_out = args[i + 1]
					i += 1
			"--mode":
				config["mode"] = args[i + 1]; i += 1
			"--base-url":
				config["base_url"] = args[i + 1]; i += 1
			"--inbox":
				config["inbox_path"] = args[i + 1]; i += 1
			"--feedback":
				config["feedback_path"] = args[i + 1]; i += 1
			"--bookmarks":
				config["bookmarks_path"] = args[i + 1]; i += 1
			"--board-json":
				config["board_json_path"] = args[i + 1]; i += 1
		i += 1

func _unhandled_key_input(event: InputEvent) -> void:
	# Ctrl+Z → undo the last skip (writes the same "unskip" row the web writes).
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_Z and (k.ctrl_pressed or k.meta_pressed):
		_undo_archive()

# ---------------------------------------------------------------------------------------------------
# scaffold — index.html's region order: chat, notifications, evolver row, bento grid
# ---------------------------------------------------------------------------------------------------

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_margin = MarginContainer.new()
	_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_margin)

	_root_vbox = VBoxContainer.new()
	_root_vbox.add_theme_constant_override("separation", GAP)
	_margin.add_child(_root_vbox)

	# ChatPanelSlot — EMBED POINT (coordination seam). The PEER lane's chat panel
	# (godot/aperture/aperture_chat_panel.tscn/.gd) mounts here; this board builds NO chat UI and
	# NO window-opening mechanism of its own — those are the peer's scenes/files. The slot mirrors
	# index.html's #aperture-chat position (pinned top). When the peer scene is present it is
	# auto-mounted (fail-open when absent; config "mount_chat": false leaves the slot empty).
	chat_panel_slot = MarginContainer.new()
	chat_panel_slot.name = "ChatPanelSlot"
	_root_vbox.add_child(chat_panel_slot)
	var chat_scene := "res://aperture/aperture_chat_panel.tscn"
	if bool(config.get("mount_chat", true)) and ResourceLoader.exists(chat_scene):
		var ps: PackedScene = load(chat_scene)
		if ps != null:
			var panel := ps.instantiate()
			if panel != null:
				if "http_base" in panel:
					panel.set("http_base", String(config["base_url"]))
				chat_panel_slot.custom_minimum_size = Vector2(0, 150)
				chat_panel_slot.add_child(panel)

	_notif_row = VBoxContainer.new()
	_notif_row.name = "NotificationsRow"          # <-> #aperture-notifications
	_notif_row.add_theme_constant_override("separation", GAP)
	_notif_row.visible = false
	_root_vbox.add_child(_notif_row)

	_evolver_row = VBoxContainer.new()
	_evolver_row.name = "EvolverRow"              # <-> #aperture-evolver-row
	_evolver_row.add_theme_constant_override("separation", GAP)
	_evolver_row.visible = false
	_root_vbox.add_child(_evolver_row)

	_masonry = HBoxContainer.new()
	_masonry.name = "Bento"                       # <-> main#aperture.bento
	_masonry.add_theme_constant_override("separation", GAP)
	_root_vbox.add_child(_masonry)
	_rebuild_columns()
	_on_resized()

func _on_resized() -> void:
	# .bento max-width 1400, centered; --gap page padding.
	var w := size.x
	var side: int = max(GAP, int((w - MAX_WIDTH) / 2.0))
	_margin.add_theme_constant_override("margin_left", side)
	_margin.add_theme_constant_override("margin_right", side)
	_margin.add_theme_constant_override("margin_top", GAP)
	_margin.add_theme_constant_override("margin_bottom", GAP)
	var want := _column_count_for(min(w, MAX_WIDTH))
	if want != _columns.size():
		_rebuild_columns()
		_relayout_grid()

## aperture.css breakpoints: 4 cols, ≤1100 → 3, ≤760 → 2, ≤480 → 1.
func _column_count_for(w: float) -> int:
	if w <= 480:
		return 1
	if w <= 760:
		return 2
	if w <= 1100:
		return 3
	return 4

func _rebuild_columns() -> void:
	for c in _masonry.get_children():
		_masonry.remove_child(c)
		c.queue_free()
	_columns.clear()
	_col_heights.clear()
	var n := _column_count_for(min(size.x, MAX_WIDTH))
	for i in n:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		col.add_theme_constant_override("separation", GAP)
		_masonry.add_child(col)
		_columns.append(col)
		_col_heights.append(0.0)

func _column_width() -> float:
	var content: float = min(size.x - 2.0 * GAP, MAX_WIDTH)
	var n: int = max(1, _columns.size())
	return (content - GAP * (n - 1)) / n

# ---------------------------------------------------------------------------------------------------
# data — fetch (http with file fallback), compose via the parity core, render regions
# ---------------------------------------------------------------------------------------------------

func refresh() -> void:
	if _root_vbox == null:
		return          # UI not built yet (_ready is deferred when added during tree bootstrap)
	var cards := await _fetch_cards()
	var board_cards := await _fetch_board_cards()
	_render_all(ApertureBoardLogic.compose(cards, board_cards, _skipped))

func _fetch_cards() -> Array:
	var mode := String(config.get("mode", "auto"))
	if mode == "http" or mode == "auto":
		var res := await _http_get(String(config["base_url"]) + "/api/aperture/inbox")
		if bool(res.get("ok", false)):
			var doc = JSON.parse_string((res["body"] as PackedByteArray).get_string_from_utf8())
			if typeof(doc) == TYPE_DICTIONARY and bool(doc.get("ok", false)):
				_mode_in_use = "http"
				for sid in doc.get("skipped", []):
					_skipped[String(sid)] = true
				var out: Array = []
				for row in doc.get("artifacts", []):
					if typeof(row) == TYPE_DICTIONARY:
						out.append(ApertureBoardLogic.normalize_row(row))
				return out
		if mode == "http":
			return []
	# file fallback — the raw substrate, mirroring the server's collapse + hide semantics.
	_mode_in_use = "file"
	return _read_inbox_file_rows()

## File channel with the RICH normalize (normalize_row): last-wins id collapse + latest-action
## hide via the shared ApertureInbox semantics, then the board-level normalization.
func _read_inbox_file_rows() -> Array:
	var rows := ApertureInbox._read_jsonl(String(config["inbox_path"]))
	var by_id := {}
	var order: Array = []
	for row in rows:
		var id := String((row as Dictionary).get("id", ""))
		if id == "":
			continue
		if not by_id.has(id):
			order.append(id)
		by_id[id] = row
	var hidden := ApertureInbox.hidden_ids(String(config["feedback_path"]))
	var out: Array = []
	for id in order:
		var row: Dictionary = by_id[id]
		if hidden.has(id):
			continue
		if String(row.get("status", "pending")) != "pending":
			continue
		out.append(ApertureBoardLogic.normalize_row(row))
	return out

func _fetch_board_cards() -> Array:
	if _board_json_loaded:
		return _board_cards_cache
	var doc = null
	if _mode_in_use == "http":
		var res := await _http_get(String(config["base_url"]) + "/static/aperture/aperture_board.json")
		if bool(res.get("ok", false)):
			doc = JSON.parse_string((res["body"] as PackedByteArray).get_string_from_utf8())
	if doc == null:
		var p := String(config.get("board_json_path", ""))
		if p != "" and FileAccess.file_exists(p):
			doc = JSON.parse_string(FileAccess.get_file_as_string(p))
	var out: Array = []
	if typeof(doc) == TYPE_DICTIONARY:
		for t in doc.get("tiles", []):
			if typeof(t) == TYPE_DICTIONARY:
				out.append(ApertureBoardLogic.normalize_board_tile(t))
	_board_cards_cache = out
	_board_json_loaded = true
	return out

func _render_all(composed: Dictionary) -> void:
	_last_compose = composed
	_render_notifications(composed.get("notifications", []))
	_render_evolver_entry(composed.get("evolver", []))
	_render_grid(composed.get("grid", []))
	# the refill queue = every composed content card (grid shows a capped prefix of it)
	_queue = (composed.get("grid", []) as Array).duplicate()

## Poll parity (web Bug-2 static ordering): the poll ONLY refreshes the notifications banner and
## the evolver entry (rebuilt on id-set change); the content grid NEVER reorders on a poll.
func _poll() -> void:
	if _shot_requested:
		return
	var cards := await _fetch_cards()
	var composed := ApertureBoardLogic.compose(cards, await _fetch_board_cards(), _skipped)
	var notifs: Array = composed.get("notifications", [])
	var nkey := _key_of(notifs)
	if nkey != _last_notif_key:
		_render_notifications(notifs)
	var evo: Array = composed.get("evolver", [])
	var ekey := _key_of(evo)
	if ekey != _last_evolver_key:
		_render_evolver_entry(evo)
	_queue = (composed.get("grid", []) as Array).duplicate()

func _key_of(cards: Array) -> String:
	var parts: Array = []
	for c in cards:
		parts.append(String((c as Dictionary).get("id", "")) + "@" + str((c as Dictionary).get("generation", -1)))
	return "|".join(parts)

# ---------------------------------------------------------------------------------------------------
# regions
# ---------------------------------------------------------------------------------------------------

func _render_notifications(cards: Array) -> void:
	_last_notif_key = _key_of(cards)
	for c in _notif_row.get_children():
		_notif_row.remove_child(c)
		c.queue_free()
	_notif_row.visible = not cards.is_empty()
	for card in cards:
		_notif_row.add_child(_build_tile(card, { "notification": true }))

## SUPERSEDED-ROUTING parity (web renderEvolverRow): the row holds ONE compact entry tile —
## "Evolution / N candidates are waiting / Open the evolution page →" — linking the dedicated
## evolution page; candidates render THERE, never on the board.
func _render_evolver_entry(cards: Array) -> void:
	_last_evolver_key = _key_of(cards)
	for c in _evolver_row.get_children():
		_evolver_row.remove_child(c)
		c.queue_free()
	_evolver_row.visible = not cards.is_empty()
	if cards.is_empty():
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _entry_style())
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)
	var title := Label.new()
	title.text = "Evolution"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", COL_INK_STRONG)
	row.add_child(title)
	var count := Label.new()
	count.text = ("%d candidate is waiting" if cards.size() == 1 else "%d candidates are waiting") % cards.size()
	count.add_theme_font_size_override("font_size", 13)
	count.add_theme_color_override("font_color", PALETTE["accent.green"])
	row.add_child(count)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var cta := Label.new()
	cta.text = "Open the evolution page →"
	cta.add_theme_font_size_override("font_size", 13)
	cta.add_theme_color_override("font_color", COL_LINK)
	row.add_child(cta)
	panel.gui_input.connect(func(ev: InputEvent):
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			OS.shell_open(String(config["base_url"]) + "/static/aperture/evolution/index.html"))
	_evolver_row.add_child(panel)

func _render_grid(cards: Array) -> void:
	_clear_grid()
	for card in cards:
		_place_tile(_build_tile(card, {}), card)

func _clear_grid() -> void:
	_displayed.clear()
	_carousels.clear()
	for col in _columns:
		for c in (col as VBoxContainer).get_children():
			(col as VBoxContainer).remove_child(c)
			c.queue_free()
	for i in _col_heights.size():
		_col_heights[i] = 0.0

func _relayout_grid() -> void:
	if _last_compose.has("grid"):
		_render_grid(_last_compose["grid"])

## Greedy masonry: place into the currently-shortest column (estimate-based). The web's CSS
## multi-column packs top-to-bottom with no holes; shortest-column is the closest Godot analog.
func _place_tile(tile: Control, card: Dictionary) -> void:
	if _columns.is_empty():
		return
	var best := 0
	for i in _columns.size():
		if _col_heights[i] < _col_heights[best]:
			best = i
	(_columns[best] as VBoxContainer).add_child(tile)
	_col_heights[best] += _estimate_height(card) + GAP
	_displayed[String(card.get("id", ""))] = tile
	tile.set_meta("col", best)

func _estimate_height(card: Dictionary) -> float:
	var w := _column_width()
	var h := 44.0
	if (card.get("images", []) as Array).size() > 0:
		h += w * 0.66
	var chars := String(card.get("title", "")).length() + String(card.get("summary", "")).length() \
		+ String(card.get("subtitle", "")).length()
	h += ceil(chars / max(1.0, w / 7.0)) * 19.0
	return h

# ---------------------------------------------------------------------------------------------------
# tile — anatomy parity with aperture.js renderContent/renderArtifact/renderQuote
# ---------------------------------------------------------------------------------------------------

func _build_tile(card: Dictionary, opts: Dictionary) -> Control:
	var is_notif := bool(opts.get("notification", false))
	var images: Array = card.get("images", [])
	var text_only := images.is_empty()
	var decision := ApertureBoardLogic.is_decision_artifact(card) and String(card.get("source", "")) == "inbox"
	var accent: Color = PALETTE.get(String(card.get("palette_token", "accent.cool")), PALETTE["accent.cool"])

	var panel := PanelContainer.new()
	panel.name = "Tile_" + String(card.get("id", ""))
	panel.set_meta("card", card)
	panel.set_meta("tile_id", String(card.get("id", "")))
	var style := _tile_style(is_notif, accent, false)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.clip_contents = false

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	# ---- image region (whole image, natural aspect — object-fit: contain parity) ----
	if images.size() > 0:
		var rect := TextureRect.new()
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(0, _column_width() * 0.6)
		rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var img_bg := StyleBoxFlat.new()
		img_bg.bg_color = COL_IMG_BG
		var img_panel := PanelContainer.new()
		img_panel.add_theme_stylebox_override("panel", img_bg)
		img_panel.add_child(rect)
		vbox.add_child(img_panel)
		if is_notif:
			rect.custom_minimum_size = Vector2(0, min(220.0, rect.custom_minimum_size.y))  # .notif-banner img cap
		_load_tile_images(panel, rect, card)

	# ---- caption: title + subtitle + summary (Spec 8: provided text only, never synthesized) ----
	var cap := MarginContainer.new()
	var pad := 16 if (text_only and not is_notif) else 10       # .tile--text-large padding
	cap.add_theme_constant_override("margin_left", pad + 2)
	cap.add_theme_constant_override("margin_right", pad + 2)
	cap.add_theme_constant_override("margin_top", pad)
	cap.add_theme_constant_override("margin_bottom", pad)
	vbox.add_child(cap)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 6)
	cap.add_child(cv)

	var is_quote := String(card.get("kind", "")) == "quote"
	var title := Label.new()
	title.text = ("“%s”" % String(card.get("title", ""))) if is_quote else String(card.get("title", ""))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.add_theme_font_size_override("font_size", 18 if (text_only and not is_notif) else (17 if is_quote else 14))
	title.add_theme_color_override("font_color", COL_INK if is_quote else COL_INK_STRONG)
	if not text_only:
		title.max_lines_visible = 3                            # .tile__title 3-line clamp
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	cv.add_child(title)

	var subtitle := String(card.get("subtitle", ""))
	var summary := String(card.get("summary", ""))
	if summary == "":
		summary = String(card.get("text", ""))
	if subtitle != "" and subtitle != summary:
		cv.add_child(_subtitle_line(("— %s" % subtitle) if is_quote else subtitle, accent, is_quote))
	if summary != "" and not is_quote:
		var body := Label.new()
		body.text = summary
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.add_theme_font_size_override("font_size", 14 if text_only else 13)
		body.add_theme_color_override("font_color", COL_INK if text_only else COL_INK_SOFT)
		if not text_only and not is_notif:
			body.max_lines_visible = 4                         # .tile__summary 4-line clamp
			body.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		cv.add_child(body)

	# ---- decision action buttons (banner decision cards; verbatim action ids) ----
	if decision and is_notif:
		var actions: Array = card.get("actions", [])
		if actions.is_empty():
			actions = [{ "id": "approve", "label": "Approve" }, { "id": "reject", "label": "Reject" }]
		var bar := HBoxContainer.new()
		bar.add_theme_constant_override("separation", 6)
		cv.add_child(bar)
		for a in actions:
			var act: Dictionary = a
			var btn := Button.new()
			btn.text = String(act.get("label", act.get("id", "")))
			btn.add_theme_font_size_override("font_size", 11)
			var bcol: Color = accent
			if String(act.get("id")) == "approve":
				bcol = PALETTE["accent.green"]
			elif String(act.get("id")) == "reject":
				bcol = PALETTE["accent.red"]
			_style_action_button(btn, bcol)
			btn.pressed.connect(func(): _decide(card, String(act.get("id")), panel))
			bar.add_child(btn)

	# ---- overlay: hover ✕ skip (top-right) + ☆ bookmark (top-left) ----
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(overlay)
	var skip_btn: Button = null
	var bm_btn: Button = null
	if not decision:
		skip_btn = _round_button("✕", PALETTE["accent.red"])
		skip_btn.tooltip_text = "Skip / remove this"
		skip_btn.pressed.connect(func(): _skip(card, panel))
		overlay.add_child(skip_btn)
		skip_btn.anchor_left = 1.0
		skip_btn.anchor_right = 1.0
		skip_btn.offset_left = -30
		skip_btn.offset_right = -6
		skip_btn.offset_top = 6
		skip_btn.offset_bottom = 30
		bm_btn = _round_button("☆", PALETTE["accent.gold"])
		bm_btn.tooltip_text = "Save this"
		bm_btn.pressed.connect(func(): _bookmark(card, bm_btn))
		overlay.add_child(bm_btn)
		bm_btn.offset_left = 6
		bm_btn.offset_right = 30
		bm_btn.offset_top = 6
		bm_btn.offset_bottom = 30
		skip_btn.visible = false
		bm_btn.visible = false

	# hover: border-hover + reveal the controls (aperture.css .tile:hover)
	panel.mouse_entered.connect(func():
		panel.add_theme_stylebox_override("panel", _tile_style(is_notif, accent, true))
		if skip_btn != null:
			skip_btn.visible = true
		if bm_btn != null:
			bm_btn.visible = true
		panel.set_meta("hovered", true))
	panel.mouse_exited.connect(func():
		panel.add_theme_stylebox_override("panel", _tile_style(is_notif, accent, false))
		if skip_btn != null:
			skip_btn.visible = false
		if bm_btn != null:
			bm_btn.visible = _bookmarked.has(_dom_id(card))   # a saved ★ stays visible
		panel.set_meta("hovered", false))

	# ---- click-through (openUrl parity: artifacts open media.link; board tiles explore) ----
	panel.gui_input.connect(func(ev: InputEvent):
		var mb := ev as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_open_card(card))
	return panel

func _subtitle_line(text: String, accent: Color, is_quote: bool) -> Control:
	# .tile__subtitle: 11px ink-soft with a 2px accent left rule (quotes drop the rule).
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not is_quote:
		var rule := ColorRect.new()
		rule.color = accent
		rule.custom_minimum_size = Vector2(2, 0)
		row.add_child(rule)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", COL_INK_FAINT if is_quote else COL_INK_SOFT)
	row.add_child(l)
	return row

func _tile_style(is_notif: bool, accent: Color, hover: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = COL_CARD_BG
	s.set_corner_radius_all(10)
	s.set_border_width_all(1)
	s.border_color = COL_CARD_BORDER_HOVER if hover else COL_CARD_BORDER
	if is_notif:
		# .notif-banner .tile: gold 3px left rule + 1px gold top accent
		s.border_color = PALETTE["accent.gold"]
		s.border_width_left = 3
		s.border_width_top = 1
	return s

func _entry_style() -> StyleBoxFlat:
	# .evolver-entry: card surface, 12/16 padding, radius 10
	var s := StyleBoxFlat.new()
	s.bg_color = COL_CARD_BG
	s.set_corner_radius_all(10)
	s.set_border_width_all(1)
	s.border_color = COL_CARD_BORDER
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 12
	s.content_margin_bottom = 12
	return s

func _round_button(glyph: String, color: Color) -> Button:
	# .tile__archive / .tile__bookmark: 24px circle, dark bg, accent glyph
	var b := Button.new()
	b.text = glyph
	b.flat = true
	b.custom_minimum_size = Vector2(24, 24)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", color)
	b.add_theme_color_override("font_hover_color", COL_INK_STRONG)
	var s := StyleBoxFlat.new()
	s.bg_color = COL_BTN_BG
	s.set_corner_radius_all(12)
	for st in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, s)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	return b

func _style_action_button(btn: Button, color: Color) -> void:
	# .art__btn: 1px accent border, radius 6, dark bg
	var s := StyleBoxFlat.new()
	s.bg_color = Color(3 / 255.0, 5 / 255.0, 9 / 255.0, 0.6)
	s.set_corner_radius_all(6)
	s.set_border_width_all(1)
	s.border_color = color
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 4
	s.content_margin_bottom = 4
	var hover := s.duplicate()
	hover.bg_color = color
	btn.add_theme_stylebox_override("normal", s)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", hover)
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", Color("06080d"))

# ---------------------------------------------------------------------------------------------------
# actions — the SAME durable writes the web board makes (shared ApertureActions write half)
# ---------------------------------------------------------------------------------------------------

func _actions() -> ApertureActions:
	var mode := _mode_in_use if _mode_in_use != "" else String(config.get("mode", "file"))
	if mode == "auto":
		mode = "file"
	return ApertureActions.new({
		"mode": mode,
		"base_url": config["base_url"],
		"feedback_path": config["feedback_path"],
		"bookmarks_path": config["bookmarks_path"],
	})

## The web DOM tile id (bookmarks are keyed on it: "tile_artifact_<apx>" / the board tile id).
func _dom_id(card: Dictionary) -> String:
	if String(card.get("source", "")) == "inbox":
		return "tile_artifact_" + String(card.get("id", ""))
	return String(card.get("id", ""))

## Skip (✕) — postSkip/decideArtifact parity: optimistic local hide + durable feedback write under
## the canonical skip_id, then the vacated slot refills IN PLACE from the queue (web Item 2).
func _skip(card: Dictionary, tile: Control) -> void:
	var sid := String(card.get("skip_id", card.get("id", "")))
	_skipped[sid] = true
	_actions().act({ "id": sid }, "skip")
	var col := tile.get_parent() as VBoxContainer
	var in_grid := _columns.has(col)                 # decideArtifact parity: only GRID slots refill
	var idx := tile.get_index()
	if col != null:
		col.remove_child(tile)
	_displayed.erase(String(card.get("id", "")))
	var refill_node: Control = null
	if in_grid:
		var replacement_card := _next_queued()
		if replacement_card.size() > 0:
			refill_node = _build_tile(replacement_card, {})
			col.add_child(refill_node)
			col.move_child(refill_node, idx)
			_displayed[String(replacement_card.get("id", ""))] = refill_node
		_last_archive = { "card": card, "col": col, "idx": idx, "refill": refill_node }
	tile.queue_free()

## nextQueuedArtifactTile parity: first queued content card not displayed, not skipped.
func _next_queued() -> Dictionary:
	for c in _queue:
		var card: Dictionary = c
		if ApertureBoardLogic.is_notification(card) or ApertureBoardLogic.is_evolver_candidate(card):
			continue
		if _skipped.has(String(card.get("skip_id", card.get("id", "")))):
			continue
		if _displayed.has(String(card.get("id", ""))):
			continue
		return card
	return {}

## Ctrl+Z — undoArchive parity: durable "unskip", the refill leaves, the original returns in place.
func _undo_archive() -> void:
	if _last_archive.is_empty():
		return
	var card: Dictionary = _last_archive["card"]
	var sid := String(card.get("skip_id", card.get("id", "")))
	_skipped.erase(sid)
	_actions().act({ "id": sid }, "unskip")
	var col := _last_archive["col"] as VBoxContainer
	var refill := _last_archive["refill"] as Control
	if refill != null and is_instance_valid(refill):
		_displayed.erase(String((refill.get_meta("card") as Dictionary).get("id", "")))
		refill.get_parent().remove_child(refill)
		refill.queue_free()
	if col != null and is_instance_valid(col):
		var restored := _build_tile(card, {})
		col.add_child(restored)
		col.move_child(restored, min(int(_last_archive["idx"]), col.get_child_count() - 1))
		_displayed[String(card.get("id", ""))] = restored
	_last_archive = {}

## ☆ Save — saveBookmark parity: optimistic ★, durable bookmark row keyed on the web DOM tile id.
func _bookmark(card: Dictionary, btn: Button) -> void:
	var dom := _dom_id(card)
	_bookmarked[dom] = true
	btn.text = "★"
	btn.tooltip_text = "Saved"
	var c := card.duplicate()
	c["id"] = dom                                  # web sends tile_id = the DOM id
	_actions().act(c, "bookmark")

## Decision buttons — decideArtifact parity: the action id is recorded verbatim; the card leaves.
func _decide(card: Dictionary, action_id: String, tile: Control) -> void:
	_skipped[String(card.get("id", ""))] = true
	_actions().act({ "id": String(card.get("id", "")) }, action_id)
	if tile.get_parent() != null:
		tile.get_parent().remove_child(tile)
	tile.queue_free()

## openUrl parity: pushed artifacts open their media.link (no fallback); quotes resolve to the
## author's page; board content tiles always reach an explorable destination.
func _open_card(card: Dictionary) -> void:
	var url := ""
	if String(card.get("source", "")) == "inbox":
		url = String(card.get("link", ""))
	elif String(card.get("kind", "")) == "quote":
		var link := String(card.get("link", ""))
		var re := RegEx.new()
		re.compile("wikipedia|britannica|\\.gov|\\.edu")
		if re.search(link) != null:
			url = link
		else:
			url = ApertureBoardLogic.explore_url({ "title": String(card.get("subtitle", card.get("title", ""))), "link": "" })
	else:
		url = ApertureBoardLogic.explore_url(card)
	if url != "":
		OS.shell_open(url)

# ---------------------------------------------------------------------------------------------------
# images — the SAME sources the web loads (media-route reverse-map / local path / http), carousel
# ---------------------------------------------------------------------------------------------------

func _load_tile_images(tile: Control, rect: TextureRect, card: Dictionary) -> void:
	var images: Array = card.get("images", [])
	if images.is_empty():
		return
	var entry := { "rect": rect, "tile": tile, "textures": [], "dots": null, "idx": 0, "want": images.size() }
	if images.size() > 1:
		_carousels.append(entry)
	for i in images.size():
		var src := ApertureBoardLogic.resolve_image_source(String(images[i]), String(config["base_url"]))
		match String(src.get("type", "none")):
			"local":
				var img := Image.new()
				if img.load(String(src["path"])) == OK:
					_apply_image(entry, i, ImageTexture.create_from_image(img))
				elif i == 0:
					_degrade_to_text(tile, rect)
			"http":
				_img_queue.append({ "url": String(src["url"]), "entry": entry, "slot": i })
				_pump_image_queue()
			_:
				if i == 0:
					_degrade_to_text(tile, rect)

func _apply_image(entry: Dictionary, slot: int, tex: Texture2D) -> void:
	var rect := entry["rect"] as TextureRect
	if rect == null or not is_instance_valid(rect):
		return
	while (entry["textures"] as Array).size() <= slot:
		(entry["textures"] as Array).append(null)
	entry["textures"][slot] = tex
	if slot == 0 or rect.texture == null:
		rect.texture = tex
		# object-fit contain at natural aspect: height follows the column width
		var w := _column_width()
		var t2 := tex.get_size()
		if t2.x > 0:
			rect.custom_minimum_size = Vector2(0, w * t2.y / t2.x)

## buildTileImg's error fallback parity: a genuinely unloadable image degrades the tile to the
## text style (never a blank tile).
func _degrade_to_text(tile: Control, rect: TextureRect) -> void:
	var wrap := rect.get_parent()
	if wrap != null and is_instance_valid(wrap):
		wrap.visible = false

func _pump_image_queue() -> void:
	while _img_workers < IMG_WORKERS_MAX and not _img_queue.is_empty():
		var job: Dictionary = _img_queue.pop_front()
		_img_workers += 1
		_run_image_job(job)

func _run_image_job(job: Dictionary) -> void:
	var res := await _http_get(String(job["url"]))
	_img_workers -= 1
	_pump_image_queue()
	if not bool(res.get("ok", false)):
		var entry: Dictionary = job["entry"]
		if int(job["slot"]) == 0:
			_degrade_to_text(entry["tile"], entry["rect"])
		return
	var img := _decode_image(res["body"] as PackedByteArray)
	if img == null:
		return
	_apply_image(job["entry"], int(job["slot"]), ImageTexture.create_from_image(img))

func _decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 4:
		return null
	var img := Image.new()
	var err := ERR_CANT_OPEN
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes.size() > 12 and bytes[8] == 0x57 and bytes[9] == 0x45:  # RIFF....WEBP
		err = img.load_webp_from_buffer(bytes)
	else:
		for loader in ["png", "jpg", "webp"]:
			match loader:
				"png": err = img.load_png_from_buffer(bytes)
				"jpg": err = img.load_jpg_from_buffer(bytes)
				"webp": err = img.load_webp_from_buffer(bytes)
			if err == OK:
				break
	return img if err == OK else null

## The ~4s cross-fade carousel (approximated as a texture swap; pause on hover — web parity).
func _advance_carousels() -> void:
	for entry in _carousels:
		var rect := entry["rect"] as TextureRect
		var tile := entry["tile"] as Control
		if rect == null or not is_instance_valid(rect) or tile == null or not is_instance_valid(tile):
			continue
		if tile.has_meta("hovered") and bool(tile.get_meta("hovered")):
			continue
		var texs: Array = entry["textures"]
		var loaded: Array = []
		for t in texs:
			if t != null:
				loaded.append(t)
		if loaded.size() <= 1:
			continue
		entry["idx"] = (int(entry["idx"]) + 1) % loaded.size()
		rect.texture = loaded[entry["idx"]]

# ---------------------------------------------------------------------------------------------------
# transport + capture
# ---------------------------------------------------------------------------------------------------

func _http_get(url: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 8.0
	add_child(req)
	if req.request(url) != OK:
		req.queue_free()
		return { "ok": false }
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) < 200 or int(res[1]) >= 300:
		return { "ok": false }
	return { "ok": true, "body": res[3] }

func _capture_shot(out_path: String) -> void:
	# let images + layout settle (bounded wait: queue drained or ~8s)
	var waited := 0.0
	while (_img_workers > 0 or not _img_queue.is_empty()) and waited < 8.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	for i in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	img.save_png(abs)
	print("[aperture_board_2d] --shot -> ", abs)
