class_name PrimAudioSource
extends Primitive
## The AUDIO SOURCE node (visi-sonor arc, Slice 1A) — the MUSIC-INPUT head of the analysis chain
## prim_audio_source -> prim_spectrum -> prim_spectrum_bands -> set_input_frame. It is the SOURCE
## sibling of Input/Sensor for a *sound stream*: where Input reads a per-frame abstract key and Sensor
## reads a sensed scalar, an AudioSource owns (in mode=mp3) a live AudioStreamPlayer feeding a dedicated
## audio bus, and emits the STREAM descriptor + the current playhead as plain DATA on wires. The bus it
## feeds is where prim_spectrum mounts Godot's built-in AudioEffectSpectrumAnalyzer — so "music -> bands"
## is one arrangement over already-registered types, never engine code (N ideal).
##
## NO-AUTO-GENERALISATION (Liam, verbatim): the seam is GENERAL (source_kind names mp3|stream|mic|loopback)
## but ONLY mp3 is wired. youtube/spotify/mic/loopback and every unknown kind are DECLARED NO-OPs — the
## exact "unknown op = declared no-op" posture device_actions/WorldActions have on the write side, here on
## the source side. A future source is a new injector writing the SAME downstream frame keys, never an edit
## to this node. So the arrangement that reacts to an mp3 today reacts to a mic tomorrow by swapping the
## kind + wiring an injector, with zero un-specced code shipped now (C ideal: a no-op kind never crashes).
##
## params:
##   source_kind — "mp3" | "stream" | "mic" | "loopback"  (default "mp3"). Only "mp3" is wired; the rest
##                 are declared no-ops that emit an empty descriptor (null stream, playhead 0.0, noop:true).
##   path        — (mp3) res:// or absolute path to the .mp3 file. Absent / unreadable => a declared
##                 MISSING no-op (ok:false, missing:true), NOT a crash — the same fail-safe direction a
##                 missing GLB takes to a placeholder mesh (C ideal).
##   bus         — the audio bus name the player routes into (where prim_spectrum mounts the analyzer).
##                 Default "VisiSonor". Created on demand if it does not exist (idempotent).
##   autoplay    — (mp3) start playing on first evaluate(). Default true. A test may set false and call
##                 play()/seek() directly.
##   loop        — (mp3) loop the stream. Default true (a demo clip loops under the light show).
##
## outputs:
##   pcm_stream       — the live AudioStream resource (AudioStreamMP3) in mp3 mode, else null. A DESCRIPTOR
##                      on a wire (T ideal): a downstream node reads it without touching this node's guts.
##   playhead_seconds — the player's current playback position in seconds (0.0 when not playing / no-op).

# The live player + stream, created lazily in mode=mp3 and parented so the tree owns their lifetime
# (the same "primitive holds a live instance" pattern the projection/model primitives use). A no-op
# kind never creates them, so a host with no audio stays inert.
var _player: AudioStreamPlayer = null
var _stream: AudioStreamMP3 = null
var _loaded_path: String = ""          # the path the current _stream was loaded from (reload detection)
var _missing: bool = false             # last load attempt failed (absent / unreadable) — a declared no-op
var _bus_ensured: String = ""          # the bus we last ensured exists (avoid re-adding every evaluate)

func _init() -> void:
	prim_type = "AudioSource"

func output_ports() -> Array:
	return [
		{ "name": "pcm_stream", "type": "any" },
		{ "name": "playhead_seconds", "type": "number" },
	]

func _kind() -> String:
	# str() (NOT String()) so a numeric/Variant params.source_kind coerces safely; String() throws on
	# a non-string — the exact crash class the spine sibling nodes document.
	return str(params.get("source_kind", "mp3"))

func _bus_name() -> String:
	var b := str(params.get("bus", "VisiSonor"))
	return b if b != "" else "VisiSonor"

## Ensure a named audio bus exists (idempotent). The analyzer prim_spectrum mounts lives on THIS bus, so
## the source guarantees the bus before the player routes into it. Additive — never removes/reorders an
## existing bus, so it composes with whatever bus layout the host already has (C ideal: safe on any host).
func ensure_bus() -> int:
	var name := _bus_name()
	var idx := AudioServer.get_bus_index(name)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(idx, name)
		# route the new bus to Master so it is audible on a real host (harmless headless).
		AudioServer.set_bus_send(idx, "Master")
	_bus_ensured = name
	return idx

func evaluate(_inputs: Dictionary) -> Dictionary:
	match _kind():
		"mp3":
			return _evaluate_mp3()
		_:
			# stream/mic/loopback + any unknown kind: DECLARED NO-OP. Empty descriptor, playhead 0.0,
			# noop:true — the same portability posture device_actions has for an unknown op. No live
			# player is created, so a host selecting an unwired kind stays inert (never a crash).
			return { "pcm_stream": null, "playhead_seconds": 0.0, "noop": true, "kind": _kind() }

# --- mp3: the ONE wired source -------------------------------------------------------------------

## Load (once, or when path changes) an AudioStreamMP3, mount an AudioStreamPlayer on the target bus,
## optionally autoplay, and emit the stream descriptor + playhead. A missing/unreadable path is a
## DECLARED no-op (ok:false, missing:true) — the C-ideal fail-safe, never a crash.
func _evaluate_mp3() -> Dictionary:
	ensure_bus()
	var path := str(params.get("path", ""))
	if path != _loaded_path:
		_load_mp3(path)   # (re)load on first eval or when the path param changes (D ideal: reload is a diff)
	if _missing or _stream == null:
		return { "pcm_stream": null, "playhead_seconds": 0.0, "ok": false, "missing": true, "path": path }
	_ensure_player()
	if bool(params.get("autoplay", true)) and not _player.playing and _player.stream != null:
		_player.play()
	var head := 0.0
	if _player != null and _player.playing:
		head = _player.get_playback_position()
	return { "pcm_stream": _stream, "playhead_seconds": head, "ok": true }

## Load an AudioStreamMP3 from `path` (res:// or absolute). Reads the file bytes and hands them to the
## stream's `data` property (the portable route that works for both bundled res:// clips and host-side
## absolute paths). A missing / unreadable file sets _missing so evaluate() emits the declared no-op.
func _load_mp3(path: String) -> void:
	_loaded_path = path
	_missing = false
	_stream = null
	if path == "":
		_missing = true
		return
	var bytes := _read_bytes(path)
	if bytes.is_empty():
		_missing = true
		return
	var s := AudioStreamMP3.new()
	s.data = bytes
	s.loop = bool(params.get("loop", true))
	_stream = s
	# if a player already exists (path changed mid-run), repoint it — a diff, not a rebuild (D ideal).
	if _player != null:
		var was_playing := _player.playing
		_player.stream = _stream
		if was_playing:
			_player.play()

## Read a file's raw bytes from res:// OR an absolute path. Returns an empty PackedByteArray when the
## file is absent/unreadable (the caller treats empty as MISSING -> declared no-op). No push_error — a
## missing clip is an expected, defined state on a host without the asset (C ideal).
func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b

## Create the live AudioStreamPlayer (once), route it to the target bus, parent it so the tree owns it.
func _ensure_player() -> void:
	if _player == null:
		_player = AudioStreamPlayer.new()
		add_child(_player)
	_player.bus = _bus_name()
	if _player.stream != _stream:
		_player.stream = _stream

# --- test / host control seams (node-wired callers use these; no GUI-only path) -------------------

## Start playback (a host/test control — the demo's play/pause). No-op if not an mp3 or not loaded.
func play() -> void:
	if _kind() == "mp3" and _stream != null and not _missing:
		_ensure_player()
		_player.play()

## Pause/stop playback. Safe when nothing is loaded.
func stop() -> void:
	if _player != null:
		_player.stop()

## Seek to a position in seconds. Safe when nothing is loaded.
func seek(seconds: float) -> void:
	if _player != null and _player.playing:
		_player.seek(seconds)

## Impure: the playhead advances with wall-clock playback, so the output is not a pure function of
## params — never memoize (the same reasoning Input/Sensor give). Const is the pure source; this is not.
func is_cacheable() -> bool:
	return false
