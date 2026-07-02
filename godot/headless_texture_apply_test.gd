extends SceneTree
## Headless verification of the LIVE-TEXTURING module (sandbox-live-verify lane, 2026-07-02):
##
##   godot --headless --path godot -s res://headless_texture_apply_test.gd
##
##   T) TextureSynth (the Godot delegate): every procedural kind synthesizes a real image, the
##      output is DETERMINISTIC for the same descriptor (content-addressable), seeds matter for
##      noise, and malformed descriptors degrade to a flat fill (never null / never crash).
##   P) PrimTextureApply (the node): emits the renderer-neutral set_material op from params or
##      wired inputs (wired wins), and an unconfigured node emits an inert {} rather than crashing.
##   G) The GRAPH path: the committed demo arrangement (examples/texture_apply_demo.json) loads
##      through GraphRuntime, evaluates, and the Log sink observes the op — functionality as an
##      arrangement of registered primitives, per the design law.
##   H) HOT-RELOAD: the arrangement is copied to user://, watched by a LiveHost, then edited on
##      disk (colour + target cell). The running graph re-emits the CHANGED op with no restart.
##   S) The SANDBOX seam: a placed block seeds UNTEXTURED, a params `material` entry seeds it
##      TEXTURED (procedural -> real albedo_texture), a `material_ops` list (the TextureApply
##      output shape) re-skins an ALREADY-PLACED block live, ops on empty cells are skipped, and
##      re-applying a DIFFERENT descriptor visibly changes the pixels (content hashes differ).

const SandboxScript := preload("res://examples/sandbox_creative.gd")
const DEMO_PATH := "res://examples/texture_apply_demo.json"

func _initialize() -> void:
	var ok := true

	# ── T) TextureSynth delegate ──────────────────────────────────────────────────────────────
	for kind in ["checker", "gradient", "noise", "bricks"]:
		var tex := TextureSynth.synthesize({ "kind": kind, "size": 32 })
		ok = _check("T1 %s synthesizes a 32x32 texture" % kind, tex is ImageTexture and tex.get_width() == 32 and tex.get_height() == 32) and ok
	var d1 := { "kind": "noise", "size": 16, "seed": 7 }
	ok = _check("T2 same descriptor -> same pixels (deterministic)", TextureSynth.content_hash(d1) == TextureSynth.content_hash(d1.duplicate(true))) and ok
	ok = _check("T3 different seed -> different noise", TextureSynth.content_hash(d1) != TextureSynth.content_hash({ "kind": "noise", "size": 16, "seed": 8 })) and ok
	ok = _check("T4 different kind -> different pixels", TextureSynth.content_hash({ "kind": "checker", "size": 16 }) != TextureSynth.content_hash({ "kind": "bricks", "size": 16 })) and ok
	var bad := TextureSynth.synthesize({ "kind": "no-such-kind", "size": -99, "colors": "junk" })
	ok = _check("T5 malformed descriptor degrades to a flat fill (never null)", bad is ImageTexture and bad.get_width() >= 2) and ok

	# ── P) the TextureApply node ──────────────────────────────────────────────────────────────
	var prim := PrimTextureApply.new()
	prim.params = { "cell": [1, 2, 3], "material": { "procedural": { "kind": "checker" } } }
	var out: Dictionary = prim.evaluate({})
	var op: Dictionary = out.get("material_op", {})
	ok = _check("P1 params-driven op has the set_material shape", op.get("op") == "set_material" and op.get("cell") == [1, 2, 3] and op.get("material", {}).has("procedural")) and ok
	out = prim.evaluate({ "spec": { "albedo": [1, 0, 0] }, "cell": [9, 9, 9] })
	op = out.get("material_op", {})
	ok = _check("P2 wired inputs win over params", op.get("cell") == [9, 9, 9] and op.get("material", {}).has("albedo") and not op.get("material", {}).has("procedural")) and ok
	var bare := PrimTextureApply.new()
	out = bare.evaluate({})
	ok = _check("P3 unconfigured node emits an inert {} (no crash)", out.get("material_op") == {}) and ok
	prim.free()
	bare.free()

	# ── G) the graph path: the committed demo arrangement ────────────────────────────────────
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	ok = _check("G1 TextureApply is registered in GraphRuntime", rt._registry.has("TextureApply")) and ok
	rt.load_json(DEMO_PATH)
	rt.evaluate()
	var log_node: PrimLog = rt.nodes.get("out")
	var gop: Dictionary = log_node.last_value if log_node != null and typeof(log_node.last_value) == TYPE_DICTIONARY else {}
	ok = _check("G2 demo arrangement emits the op through the Log sink", gop.get("op") == "set_material" and gop.get("cell") == [0, 1, 0]) and ok
	ok = _check("G3 the op carries the checker spec from the Const", gop.get("material", {}).get("procedural", {}).get("kind") == "checker") and ok

	# ── H) hot-reload via LiveHost (edit the arrangement on disk, no restart) ─────────────────
	var live_path := "user://texture_apply_live.json"
	var arr = JSON.parse_string(FileAccess.get_file_as_string(DEMO_PATH))
	_write(live_path, arr)
	var rt2 := GraphRuntime.new()
	get_root().add_child(rt2)
	var host := LiveHost.new()
	host.runtime = rt2
	host.path = live_path
	get_root().add_child(host)
	ok = _check("H1 LiveHost loads the arrangement", host.poll_once()) and ok
	var log2: PrimLog = rt2.nodes.get("out")
	var hop: Dictionary = log2.last_value if typeof(log2.last_value) == TYPE_DICTIONARY else {}
	ok = _check("H2 initial op observed (cell [0,1,0])", hop.get("cell") == [0, 1, 0]) and ok
	# Simulate Claude/Liam editing the texture + target live: new colours, new kind, new cell.
	arr["rev"] = 2
	for n in arr["nodes"]:
		if n["id"] == "spec":
			n["params"]["value"]["procedural"] = { "kind": "bricks", "size": 32, "colors": [[0.7, 0.2, 0.2], [0.9, 0.9, 0.9]] }
		if n["id"] == "target":
			n["params"]["value"] = [2, 0, 2]
	_write(live_path, arr)
	ok = _check("H3 content change detected -> reload", host.poll_once()) and ok
	hop = log2.last_value if typeof(log2.last_value) == TYPE_DICTIONARY else {}
	ok = _check("H4 edited op re-emitted live (bricks @ [2,0,2], no restart)", hop.get("cell") == [2, 0, 2] and hop.get("material", {}).get("procedural", {}).get("kind") == "bricks") and ok

	# ── S) the sandbox seam consumes the ops ─────────────────────────────────────────────────
	var s = SandboxScript.new()
	s._headless = true
	s._build_palette()
	s._default_hotbar()
	s._build_world_nodes()
	get_root().add_child(s)
	# Untextured by default; textured at SEED time via a per-block material entry.
	s._seed_world({ "blocks": [
		{ "cell": [0, 0, 0], "block": "Cube" },
		{ "cell": [1, 0, 0], "block": "Cube", "material": { "procedural": { "kind": "checker", "size": 32 } } },
	] }, true)
	var plain := _mat(s, Vector3i(0, 0, 0))
	var seeded := _mat(s, Vector3i(1, 0, 0))
	ok = _check("S1 plain block seeds untextured", plain.albedo_texture == null) and ok
	ok = _check("S2 material-carrying block seeds TEXTURED (procedural -> albedo_texture)", seeded.albedo_texture is ImageTexture) and ok
	# Re-skin the ALREADY-PLACED plain block with the op the graph emitted in G (live texturing).
	var applied: int = s._apply_material_ops([ { "op": "set_material", "cell": [0, 0, 0], "material": gop.get("material", {}) } ])
	plain = _mat(s, Vector3i(0, 0, 0))
	ok = _check("S3 a TextureApply op re-skins a placed block live", applied == 1 and plain.albedo_texture is ImageTexture) and ok
	ok = _check("S4 the op's roughness rode along through the seam", absf(plain.roughness - 0.7) < 0.001) and ok
	ok = _check("S5 ops on empty cells are skipped (no crash)", s._apply_material_ops([ { "cell": [9, 9, 9], "material": { "albedo": [1, 1, 1] } }, "junk", { "cell": "bad" } ]) == 0) and ok
	# A DIFFERENT descriptor visibly changes the pixels (content hash differs) - texture ITERATION.
	var h_before: String = (plain.albedo_texture as ImageTexture).get_image().get_data().hex_encode().md5_text()
	s._apply_material_ops([ { "cell": [0, 0, 0], "material": { "procedural": { "kind": "gradient", "size": 32, "colors": [[0, 0, 0], [1, 1, 1]] } } } ])
	plain = _mat(s, Vector3i(0, 0, 0))
	var h_after: String = (plain.albedo_texture as ImageTexture).get_image().get_data().hex_encode().md5_text()
	ok = _check("S6 re-applying a different descriptor changes the pixels", h_before != h_after) and ok
	# The hotload path end-to-end: _seed_world with material_ops in the cfg (what the params file carries).
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ],
		"material_ops": [ { "cell": [0, 0, 0], "material": { "procedural": { "kind": "noise", "size": 32, "seed": 3 } } } ] }, true)
	ok = _check("S7 params-file material_ops texture the world on (hot)load", _mat(s, Vector3i(0, 0, 0)).albedo_texture is ImageTexture) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	# Explicit teardown BEFORE quit: nodes still in the tree hold live ImageTextures/materials, and
	# letting engine shutdown free them after the RenderingServer is gone segfaults headless Godot
	# at exit (observed: ALL PASS then exit 139). Free bottom-up while the servers are still alive.
	s._seed_world({ "blocks": [] }, true)
	for n in [s, host, rt2, rt]:
		get_root().remove_child(n)
		n.free()
	quit(0 if ok else 1)


func _mat(s, cell: Vector3i) -> StandardMaterial3D:
	var n: MeshInstance3D = s.world[cell]["node"]
	return n.material_override as StandardMaterial3D

func _write(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _check(label: String, cond: bool) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	return cond
