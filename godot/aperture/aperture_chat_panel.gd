class_name ApertureChatPanel
extends Control
## The GODOT APERTURE CHAT PANEL — the in-engine twin of the web board's pinned composer
## (RW static/aperture/chat_composer.js). Liam types iteration requests here and they land in
## the SAME durable channel the web composer writes, so the session-routing hooks (claim /
## label / read) fire identically no matter which surface he types into.
##
## Transport (http-first, file-fallback — mirrors ApertureInbox's two channels):
##   * send:    POST {http_base}/api/aperture/chat/send {"text": …} — the exact web route, so
##              the server applies the same durable double-write. If the server is down, the
##              panel falls back to ApertureChatStore.append_message (same files, same order).
##   * history: GET {http_base}/api/aperture/chat/history?limit=N; fallback
##              ApertureChatStore.fold(chat_dir). Gentle polling; backs off on error.
##
## EMBEDDABLE: the root is a plain Control — instance `aperture_chat_panel.tscn` under any
## board's ChatPanelSlot (the 2D board leaves one) or run the scene standalone
## (godot --path godot res://aperture/aperture_chat_panel.tscn) for a full-window chat.

## The Aperture web server. Empty ⇒ file-only mode.
@export var http_base: String = "http://127.0.0.1:8770"
## The chat substrate dir for the file fallback. Empty ⇒ ApertureChatStore.default_chat_dir().
@export var chat_dir: String = ""
## Sender id recorded on messages typed into THIS panel. The web composer sends as "liam";
## this panel is also Liam typing, so the default matches — equivalence, not impersonation.
@export var sender: String = "liam"
## Latest-N history window (matches the web expand page's practical window).
@export var history_limit: int = 200
## Base poll cadence (the web composer polls at 8s; same gentle default).
@export var poll_seconds: float = 8.0

var _history_box: VBoxContainer
var _scroll: ScrollContainer
var _input: LineEdit
var _send_btn: Button
var _status: Label
var _poll_timer: Timer
var _http_history: HTTPRequest
var _http_send: HTTPRequest
var _pending_send_text: String = ""
var _backoff: float = 0.0
var _last_render_key: String = ""

signal message_sent(row: Dictionary)
signal history_updated(messages: Array)


func _ready() -> void:
	if chat_dir == "":
		chat_dir = ApertureChatStore.default_chat_dir()
	_build_ui()
	_http_history = HTTPRequest.new()
	_http_history.timeout = 4.0
	add_child(_http_history)
	_http_history.request_completed.connect(_on_history_response)
	_http_send = HTTPRequest.new()
	_http_send.timeout = 6.0
	add_child(_http_send)
	_http_send.request_completed.connect(_on_send_response)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = poll_seconds
	_poll_timer.autostart = true
	add_child(_poll_timer)
	_poll_timer.timeout.connect(refresh)
	refresh.call_deferred()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	var title := Label.new()
	title.text = "Aperture chat"
	title.add_theme_font_size_override("font_size", 14)
	root.add_child(title)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(_scroll)
	_history_box = VBoxContainer.new()
	_history_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_box.add_theme_constant_override("separation", 4)
	_scroll.add_child(_history_box)

	var row := HBoxContainer.new()
	root.add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = "Type an iteration request…"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_t): _send())
	row.add_child(_input)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_send)
	row.add_child(_send_btn)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 10)
	_status.modulate = Color(1, 1, 1, 0.6)
	root.add_child(_status)


# ------------------------------------------------------------------ send (http → file)
func _send() -> void:
	var text := _input.text
	if text.strip_edges() == "":
		return
	_send_btn.disabled = true
	_pending_send_text = text
	if http_base != "":
		var body := JSON.stringify({"text": text})
		var err := _http_send.request(http_base + "/api/aperture/chat/send",
			["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
		if err == OK:
			return
	_send_via_file()


func _on_send_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var data = JSON.parse_string(body.get_string_from_utf8())
		var mid := String(data.get("id", "")) if typeof(data) == TYPE_DICTIONARY else ""
		_after_send({"id": mid, "text": _pending_send_text, "from": sender}, "sent (web route)")
		return
	# Server unreachable / 5xx → durable file fallback (same store, same persist order).
	_send_via_file()


func _send_via_file() -> void:
	var row := ApertureChatStore.append_message(chat_dir, sender, _pending_send_text)
	if row.is_empty():
		_status.text = "send FAILED (server down and file write failed)"
		_send_btn.disabled = false
		return
	_after_send(row, "sent (direct to channel; server offline)")


func _after_send(row: Dictionary, note: String) -> void:
	_status.text = note
	_pending_send_text = ""
	_input.clear()
	_send_btn.disabled = false
	message_sent.emit(row)
	refresh()


# ------------------------------------------------------------------ history (http → file)
func refresh() -> void:
	if http_base != "":
		var url := http_base + "/api/aperture/chat/history?limit=%d" % history_limit
		if _http_history.request(url) == OK:
			return
	_render(ApertureChatStore.fold(chat_dir))


func _on_history_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_backoff = 0.0
		_poll_timer.wait_time = poll_seconds
		_render(ApertureChatStore.parse_history_body(body.get_string_from_utf8()))
		return
	# Backoff + file fallback so a down server never blanks or hammers anything.
	_backoff = clampf((_backoff * 2.0) if _backoff > 0.0 else poll_seconds, poll_seconds, 60.0)
	_poll_timer.wait_time = _backoff
	_render(ApertureChatStore.fold(chat_dir))


func _render(messages: Array) -> void:
	var tail := messages.slice(maxi(0, messages.size() - history_limit))
	# Cheap change-detection so polling does not rebuild (and scroll-jump) an unchanged list.
	var key := "%d:%s" % [tail.size(),
		String(tail.back().get("id", "")) if not tail.is_empty() else ""]
	if key == _last_render_key:
		return
	_last_render_key = key
	for c in _history_box.get_children():
		c.queue_free()
	for m in tail:
		var who := String(m.get("from", ""))
		var lbl := RichTextLabel.new()
		lbl.fit_content = true
		lbl.bbcode_enabled = false
		lbl.selection_enabled = true
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name := "you" if who == sender else who.split("-")[0].substr(0, 12)
		lbl.text = "[%s] %s" % [name, String(m.get("text", ""))]
		lbl.modulate = Color(0.85, 0.95, 1.0) if who == sender else Color(1, 1, 1)
		_history_box.add_child(lbl)
	history_updated.emit(tail)
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)
