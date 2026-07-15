class_name ParamChannelClient
extends RefCounted
## ParamChannelClient -- native GDScript client for the SAME param_channel/ws:// wire protocol
## Wavelet's Python side already speaks (Wavelet PR #910: `projection/graph/param_channel_node.py`
## + `projection/transport/ws_endpoint.py` + `projection/transport/ws_relay_server.py`). This is the
## follow-up `tunable_panel.gd`'s own docstring names (DQ-0343912a): "carry this panel's live edits
## out over the existing param_channel/ws:// transport for cross-window/cross-device tuning."
##
## NOT a new transport -- a same-protocol reimplementation. The wire shape is Python's
## `ParamMessage.to_wire()`/`from_wire()`: flat JSON `{"param": <name>, "value": <...>, "ts": <epoch
## seconds>}`, one text frame per message, over a room keyed by the WebSocket URL's PATH
## (`ws://host:port/room-name`). Godot's built-in `WebSocketPeer` speaks the same standard WS
## handshake `ws_relay_server.py` (the `websockets` library) and any browser both already speak, so a
## Godot scene, a browser tab, and a Python process can all join the SAME room and see each other's
## messages -- "abstractable to any two windows... including on other devices" made concrete for the
## engine side (the Python side is already concrete; this is engine-side parity, not a new design).
##
## API:
##   ParamChannelClient.new(uri)      -- eager-connects (matches Endpoint's own "open_endpoint()
##                                        returns a READY endpoint" contract, WsEndpoint's own
##                                        docstring).
##   poll() -> void                   -- call ONCE PER FRAME. Pumps the socket + drives
##                                        reconnect-with-backoff on a dropped link (mirrors
##                                        WsEndpoint's transparent reconnect).
##   is_open() -> bool
##   publish(param: String, value) -> void          -- send one {param,value,ts} message. Silently
##                                                      dropped if the socket is not yet OPEN (the
##                                                      same fail-open posture this whole corpus uses
##                                                      for a not-yet-ready transport; a caller that
##                                                      needs guaranteed delivery should check
##                                                      is_open() first).
##   drain_latest() -> Dictionary     -- read every message received since the last call, collapsed
##                                        to the LATEST value per param name (last-write-wins, the
##                                        SAME resolution `param_channel_latest()` implements
##                                        server-side). Call AFTER poll().
##   close() -> void
##
## schema-version: 1.0.0

const RECONNECT_DELAY_INITIAL_MS := 100
const RECONNECT_DELAY_MAX_MS := 2000

var _socket: WebSocketPeer
var _uri: String = ""
var _reconnect_delay_ms: int = RECONNECT_DELAY_INITIAL_MS
var _last_attempt_ms: int = 0
var _closed := false


func _init(uri: String) -> void:
	_uri = uri
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(_uri)
	if err != OK:
		push_warning("ParamChannelClient: connect_to_url(%s) failed, err=%s -- will retry on poll()" % [_uri, err])
	_last_attempt_ms = Time.get_ticks_msec()


## Call once per frame (e.g. from a scene's `_process`). Pumps the socket and, if the link is
## CLOSED, retries with exponential backoff (capped) -- the same "transparent reconnect, never
## raises to the caller" contract `WsEndpoint` gives on the Python side.
func poll() -> void:
	if _socket == null or _closed:
		return
	_socket.poll()
	if _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		var now := Time.get_ticks_msec()
		if now - _last_attempt_ms >= _reconnect_delay_ms:
			_last_attempt_ms = now
			_socket.connect_to_url(_uri)
			_reconnect_delay_ms = mini(_reconnect_delay_ms * 2, RECONNECT_DELAY_MAX_MS)


func is_open() -> bool:
	return _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN


## Human-readable connection state (diagnostics only, e.g. a caller printing periodic status in a
## headless/batch run where there is no other visibility into the socket).
func state_string() -> String:
	if _socket == null:
		return "NO_SOCKET"
	match _socket.get_ready_state():
		WebSocketPeer.STATE_CONNECTING: return "CONNECTING"
		WebSocketPeer.STATE_OPEN: return "OPEN"
		WebSocketPeer.STATE_CLOSING: return "CLOSING"
		WebSocketPeer.STATE_CLOSED: return "CLOSED(code=%s)" % _socket.get_close_code()
		_: return "UNKNOWN"


## Send one param-changed message. Silently a no-op if the link isn't OPEN yet (fail-open --
## matches the rest of this corpus's "never raises for a not-yet-ready resource" posture); a caller
## that needs delivery guarantees should check `is_open()` first.
func publish(param: String, value) -> void:
	if not is_open():
		return
	_socket.send_text(encode_message(param, value))


## Read every frame currently buffered, decode, and collapse to the LATEST value per param name
## (last-write-wins -- the same resolution `param_channel_latest()` gives server-side). Call this
## AFTER `poll()` each frame. Malformed frames are skipped, never raise (a stray non-JSON or
## missing-"param" frame from a misbehaving peer must not crash the receiving scene).
func drain_latest() -> Dictionary:
	var latest := {}
	if _socket == null:
		return latest
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		var text := packet.get_string_from_utf8()
		var decoded := decode_message(text)
		if decoded.has("param"):
			latest[String(decoded["param"])] = decoded.get("value")
	return latest


func close() -> void:
	if _socket != null and not _closed:
		_socket.close()
		_closed = true


## ---- pure wire-format helpers (no socket I/O -- testable in isolation, mirrors Python's
##      ParamMessage.to_wire()/from_wire() field-for-field) ----

static func encode_message(param: String, value, ts: float = -1.0) -> String:
	var stamp := ts if ts >= 0.0 else Time.get_unix_time_from_system()
	return JSON.stringify({"param": param, "value": value, "ts": stamp})


## Returns `{}` (not null) for anything that isn't a well-formed `{"param": ...}` message --
## callers check `.has("param")`, never a type/null check, so a malformed frame degrades to "no
## message" rather than a crash.
static func decode_message(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("param"):
		return {}
	return parsed
