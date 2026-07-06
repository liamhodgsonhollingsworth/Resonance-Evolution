extends RefCounted
## WorldActions — a param-configured SIDE-EFFECT SINK REGISTRY (Dreams-arc Slice 1).
##
## This is the shared "Action" module: the ONE place a wired arrangement is allowed to reach OUT of
## pure dataflow and cause an effect in the world. It is modelled DIRECTLY on the proof that such a
## sink is legal inside a Primitive.evaluate() — ApertureActions (runtime/aperture_actions.gd), wrapped
## by PrimApertureAction: a params-configured writer whose one public method returns a plain receipt.
## WorldActions generalizes that from ONE hard-wired effect (a card decision) to a small, EXTENSIBLE
## registry of named ops, so "add a world effect" == "register one op", never an engine edit.
##
## THE CONTRACT (load-bearing, and what the later `device.*` / `app.*` / `spotify.*` families inherit):
##   • An op is a pure NAME + a param dict + the wire inputs. `perform(op, args)` returns a DATA receipt
##     `{ ok: bool, op: String, ... }` — never a live node, never a signal. So a WorldAction node stays a
##     normal dataflow node whose OUTPUT is serialisable, exactly like every other primitive.
##   • UNKNOWN OP = A DECLARED NO-OP (not an error). `perform("device.ir_send", …)` on a host with no IR
##     blaster returns `{ ok: true, op: "device.ir_send", noop: true, reason: "unknown op" }`. This is the
##     property that lets the SAME arrangement run on a game host, a website, a phone, and a room of real
##     lights: a host simply registers the ops it can honour; everything else silently no-ops. (The wide
##     device/app catalog is a LATER slice — this module ships the minimal set that proves the seam.)
##   • Effects are routed through an injectable SINK so a headless test drives the exact same code with
##     zero real side effects (the aperture_actions file-mode pattern). Default sink = Godot's logger.
##
## MINIMAL OP SET (Slice 1 — deliberately tiny; the catalog comes later, per the no-auto-generalize rule):
##   • "log"       — record a message. args: { message } (or the wired `value`). The canonical harmless
##                   effect; proves the sink round-trips. Receipt carries the logged text.
##   • "set_param" — request a single param write on a target node in an arrangement. args:
##                   { target, key, value }. This does NOT mutate anything by itself — it emits a
##                   *set_param op receipt* (target/key/value as DATA) that a consumer (the graph_store
##                   write seam / a host) applies as a diff-hotload. Keeping it declarative preserves
##                   node-not-edit: the effect is a data receipt, the application is the existing write path.
##   • "noop"      — an explicit do-nothing (useful as a wired placeholder / disabled action).
##
## Portability: no Godot Node/scene types in the public surface — only Dictionaries + Strings + a plain
## Callable sink. A GDScript ≡ Python ≡ JS re-implementation only has to match `perform`'s receipt dict.

## The ops this registry can honour. name(String) -> Callable(args:Dictionary) -> receipt(Dictionary).
## An op absent here is a DECLARED NO-OP (see perform()), never an error.
var _ops: Dictionary = {}

## The BUILT-IN op names a host-wide registration may NOT shadow. register_host() refuses any op that
## collides with one of these so a device/ui/app family (or a careless later slice) can never silently
## override the load-bearing primitives — the exact cross-slice N-violation the Slice-7 verifier flagged.
## Kept in ONE place so it stays in sync with _register_builtins() (the single source of the builtin set).
const _BUILTIN_OPS := ["log", "set_param", "noop"]

## HOST-WIDE ops registered once at boot (Dreams-arc Slice 7 seam). A host with hardware (a room of
## lights / an IR blaster) registers its device.* family HERE via register_host() at boot; thereafter
## EVERY WorldActions instance — including the fresh one PrimWorldAction builds per-evaluate — inherits
## them in _init(). A host with no hardware never registers, so this stays empty and device.* falls
## through the unknown-op declared-no-op path. This is the "a host registers its device.* at boot"
## model: purely additive (an empty registry changes nothing for existing graphs), opt-in, host-wide.
static var _host_ops: Dictionary = {}


## Register (or replace) a HOST-WIDE op that every subsequently-constructed WorldActions inherits. The
## boot seam for the device.*/app.* families (a host calls this once; DeviceActions.register_device_ops
## routes through here). Additive by construction — never touches the per-instance dispatch.
##
## THE BUILTIN-SHADOW GUARD (Slice 5, closing the cross-slice N-violation the Slice-7 verifier flagged):
## a host op that collides with a BUILTIN name (log/set_param/noop) is REFUSED — it is NOT registered and
## register_host returns false with a warning, rather than silently overriding a load-bearing primitive.
## This makes "add a world effect == register one op" safe by construction: a new family can never quietly
## replace the sink the whole system logs through / diff-hotloads through. Returns true iff the op was
## registered (bool so a boot step / test can assert the refusal). A non-shadowing op registers as before.
static func register_host(op: String, fn: Callable) -> bool:
	if op == "":
		return false
	if _BUILTIN_OPS.has(op):
		push_warning("WorldActions.register_host: refusing to shadow builtin op '%s' (host op ignored)" % op)
		return false
	_host_ops[op] = fn
	return true


## Remove a host-wide op (returns to the "unknown op = declared no-op" baseline for it). No-op if absent.
static func unregister_host(op: String) -> void:
	_host_ops.erase(op)

## Where "log"-family effects go. A Callable(String) — default prints through Godot's logger. A test
## injects its own sink (e.g. append to an Array) so it observes the effect with no real side effect.
var _log_sink: Callable = Callable()

## Config carried from the node's params (mode / target defaults / by-line etc.), mirrored from the
## ApertureActions(params) shape. Unused keys are ignored; present so hosts can pass through settings.
var config: Dictionary = {}


## `cfg` mirrors PrimApertureAction's params dict. `log_sink` (optional) overrides where "log" writes;
## when unset, logs go through Godot's print. Registers the minimal built-in op set.
func _init(cfg: Dictionary = {}, log_sink: Callable = Callable()) -> void:
	config = cfg.duplicate(true) if cfg != null else {}
	_log_sink = log_sink
	_register_builtins()
	# Inherit any HOST-WIDE ops a host registered at boot (device.*/app.* families). Empty for a host
	# with no hardware, so this changes nothing in the default case; opt-in per register_host().
	for op in _host_ops:
		_ops[op] = _host_ops[op]


## Register (or replace) an op. This is the ENTIRE extension surface — a new world effect is one call
## here (a host registers its `device.*` at boot; a later slice registers the wide catalog). Additive
## by construction: registering an op never touches the dispatch below.
func register(op: String, fn: Callable) -> void:
	if op == "":
		return
	_ops[op] = fn


## Is `op` honoured by this registry? (False => perform() returns a declared no-op receipt.)
func has_op(op: String) -> bool:
	return _ops.has(op)


## The sorted list of registered op names (drives the panel's op picker + tests).
func ops() -> Array:
	var names := _ops.keys()
	names.sort()
	return names


## Perform one op. Returns a DATA receipt. The load-bearing rule: an UNKNOWN op is a DECLARED NO-OP
## (ok:true, noop:true) — NOT an error — so an arrangement authored against a richer host still runs
## here, its unsupported effects harmlessly skipped. `args` merges the node params with the wire inputs
## (the caller decides precedence; PrimWorldAction feeds wired inputs over params).
func perform(op: String, args: Dictionary = {}) -> Dictionary:
	if op == "" or op == "noop":
		return { "ok": true, "op": "noop", "noop": true }
	if not _ops.has(op):
		# The portability keystone: unknown op is a declared no-op, never a failure.
		return { "ok": true, "op": op, "noop": true, "reason": "unknown op" }
	var fn: Callable = _ops[op]
	if not fn.is_valid():
		return { "ok": false, "op": op, "error": "op has no valid handler" }
	var receipt = fn.call(args)
	if typeof(receipt) != TYPE_DICTIONARY:
		return { "ok": true, "op": op, "result": receipt }
	return receipt


# --- built-in ops ----------------------------------------------------------------------------------

func _register_builtins() -> void:
	register("log", _op_log)
	register("set_param", _op_set_param)
	register("noop", func(_a): return { "ok": true, "op": "noop", "noop": true })


## "log": record a message through the injected sink (or Godot's print). The simplest real effect —
## proves the arrangement can reach the world and get a receipt back.
func _op_log(args: Dictionary) -> Dictionary:
	# str() (not String()) — the wired `value` may be any Variant (an int/float from a Const); the
	# String() type-constructor only accepts String/StringName/NodePath and throws on a bare number.
	var msg := str(args.get("message", args.get("value", "")))
	if _log_sink.is_valid():
		_log_sink.call(msg)
	else:
		print("[WorldActions.log] ", msg)
	return { "ok": true, "op": "log", "message": msg }


## "set_param": emit a DECLARATIVE set-param receipt (target/key/value as DATA). It does NOT mutate a
## node itself — it returns the write REQUEST, which the existing graph_store / host write path applies
## as a diff-hotload. This keeps the effect node-not-edit: the action is data; the application is the
## already-existing write seam.
func _op_set_param(args: Dictionary) -> Dictionary:
	# str() coerces any wired Variant target/key id to text (String() would throw on a wired number).
	var target := str(args.get("target", ""))
	var key := str(args.get("key", ""))
	if target == "" or key == "":
		return { "ok": false, "op": "set_param", "error": "target and key are required" }
	return { "ok": true, "op": "set_param", "target": target, "key": key,
		"value": args.get("value") }
