class_name PrimApertureInbox
extends Primitive
## The APERTURE INBOX node — surfaces the live Aperture inbox (the same substrate the web board
## renders) as wirable DATA. Source selection is a param, per the two-channel contract in
## ApertureInbox (the shared pure-data module — this node is a thin wire around it):
##   - params.source = "body": normalize an HTTP /api/aperture/inbox response body handed in on
##     the `body` input (the scene owns the async fetch; primitives evaluate synchronously).
##   - params.source = "file": read the substrate JSONL directly (params.inbox_path +
##     params.feedback_path) — the :8770-down fallback, and the fixture path for tests.
## Output `cards` is the normalized card list (see ApertureInbox.normalize_card).

func _init() -> void:
	prim_type = "ApertureInbox"

func input_ports() -> Array:
	return [{ "name": "body", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "cards", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var source := String(params.get("source", "file"))
	if source == "body":
		var body := String(inputs.get("body", "")) if inputs.get("body") != null else ""
		return { "cards": ApertureInbox.parse_inbox_body(body) }
	return { "cards": ApertureInbox.read_inbox_file(
		String(params.get("inbox_path", "")), String(params.get("feedback_path", ""))) }
