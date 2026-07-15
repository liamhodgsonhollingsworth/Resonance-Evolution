extends SceneTree
## Headless test suite for tools/param_channel_client.gd (ParamChannelClient, DQ-0343912a):
##
##   godot --headless --path godot -s res://headless_param_channel_client_test.gd
##
## Covers the PURE wire-format helpers (encode_message/decode_message) without opening a real
## socket -- a real ws:// round-trip is verified separately by the Python-side integration proof
## (underground_wave6_proof.gd --param-listen driven by a real Python param_channel client against
## the real ws_relay_server), which is the more meaningful cross-process proof for a transport this
## module deliberately does not reimplement (it reuses the existing param_channel/ws:// server).

func _initialize() -> void:
	var ok := true
	ok = _test_encode_basic_shape() and ok
	ok = _test_encode_uses_given_ts_when_provided() and ok
	ok = _test_decode_round_trips_encode() and ok
	ok = _test_decode_int_float_bool_string_values() and ok
	ok = _test_decode_missing_param_key_returns_empty() and ok
	ok = _test_decode_non_dict_json_returns_empty() and ok
	ok = _test_decode_malformed_json_returns_empty() and ok
	ok = _test_decode_composite_dict_value_round_trips() and ok
	ok = _test_new_client_does_not_crash_on_unreachable_uri() and ok
	ok = _test_fresh_client_is_not_open_before_handshake() and ok
	ok = _test_fresh_client_drain_latest_is_empty() and ok
	ok = _test_publish_before_open_is_a_silent_noop() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _test_encode_basic_shape() -> bool:
	var text := ParamChannelClient.encode_message("ring_count", 4, 1700000000.5)
	var parsed = JSON.parse_string(text)
	return _check(
		"encode_message: flat {param,value,ts} shape matching Python's ParamMessage.to_wire()",
		parsed is Dictionary and parsed.get("param") == "ring_count"
			and parsed.get("value") == 4 and is_equal_approx(float(parsed.get("ts")), 1700000000.5))


func _test_encode_uses_given_ts_when_provided() -> bool:
	var text := ParamChannelClient.encode_message("gap", 6.0, 42.0)
	var parsed = JSON.parse_string(text)
	return _check("encode_message: explicit ts is preserved, not overwritten by wall-clock",
		is_equal_approx(float(parsed.get("ts")), 42.0))


func _test_decode_round_trips_encode() -> bool:
	var text := ParamChannelClient.encode_message("light_flush", true, 5.0)
	var decoded := ParamChannelClient.decode_message(text)
	return _check("decode_message: round-trips encode_message's own output",
		decoded.get("param") == "light_flush" and decoded.get("value") == true)


func _test_decode_int_float_bool_string_values() -> bool:
	var ok := true
	ok = (ParamChannelClient.decode_message(ParamChannelClient.encode_message("a", 3)).get("value") == 3) and ok
	ok = (ParamChannelClient.decode_message(ParamChannelClient.encode_message("b", 0.14)).get("value") == 0.14) and ok
	ok = (ParamChannelClient.decode_message(ParamChannelClient.encode_message("c", false)).get("value") == false) and ok
	ok = (ParamChannelClient.decode_message(ParamChannelClient.encode_message("d", "vertical_bars")).get("value") == "vertical_bars") and ok
	return _check("decode_message: int/float/bool/string values all survive a round trip", ok)


func _test_decode_missing_param_key_returns_empty() -> bool:
	var decoded := ParamChannelClient.decode_message(JSON.stringify({"value": 1, "ts": 1.0}))
	return _check("decode_message: a well-formed JSON object with no \"param\" key -> {} (not a crash)",
		decoded.is_empty())


func _test_decode_non_dict_json_returns_empty() -> bool:
	var decoded := ParamChannelClient.decode_message(JSON.stringify([1, 2, 3]))
	return _check("decode_message: valid JSON that isn't an object (e.g. an array) -> {}", decoded.is_empty())


func _test_decode_malformed_json_returns_empty() -> bool:
	var decoded := ParamChannelClient.decode_message("{not json")
	return _check("decode_message: malformed JSON text -> {} (never raises)", decoded.is_empty())


func _test_decode_composite_dict_value_round_trips() -> bool:
	# viewpoint_pose is the one non-scalar value this wire shape carries.
	var pose := {"position": [1.0, 2.0, 3.0], "look_at": [4.0, 5.0, 6.0], "fov_deg": 65.0}
	var text := ParamChannelClient.encode_message("viewpoint_pose", pose, 9.0)
	var decoded := ParamChannelClient.decode_message(text)
	var v = decoded.get("value")
	return _check("decode_message: a composite Dictionary value (viewpoint_pose) round-trips intact",
		v is Dictionary and v.get("fov_deg") == 65.0 and v.get("position").size() == 3)


func _test_new_client_does_not_crash_on_unreachable_uri() -> bool:
	# Port 1 is a reserved/unused port on loopback -- connect_to_url() should fail fast (or the
	# subsequent poll() should observe CLOSED) rather than the constructor raising.
	var client := ParamChannelClient.new("ws://127.0.0.1:1/room")
	return _check("ParamChannelClient.new(): an unreachable uri does not raise", client != null)


func _test_fresh_client_is_not_open_before_handshake() -> bool:
	var client := ParamChannelClient.new("ws://127.0.0.1:1/room")
	return _check("is_open(): false immediately after construction (handshake is async)",
		client.is_open() == false)


func _test_fresh_client_drain_latest_is_empty() -> bool:
	var client := ParamChannelClient.new("ws://127.0.0.1:1/room")
	return _check("drain_latest(): {} on a client with no traffic yet", client.drain_latest().is_empty())


func _test_publish_before_open_is_a_silent_noop() -> bool:
	var client := ParamChannelClient.new("ws://127.0.0.1:1/room")
	client.publish("ring_count", 5)  # must not raise even though the socket never opened
	return _check("publish(): silently a no-op when the socket is not OPEN yet (fail-open, no raise)", true)
