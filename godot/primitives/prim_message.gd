class_name PrimMessage
extends Primitive
## A conversation / idea node: one chat turn OR one authored idea, stored as DATA. The whole
## nonlinear conversation is an arrangement of Message nodes wired reply -> parent; a node
## with several incoming `parent` wires is a MERGE (the graph is a DAG, not just a tree).
## "Branch" vs "reply" is NOT a node property — it is just whether the parent was the active
## tip when the child was made, so no wire-intent field is needed (and wires are schema-strict
## anyway). Context for an LLM turn is assembled by WALKING the parent wires (see
## ConvoProtocol), never by dataflow evaluation, so evaluate() just exposes this node's own
## record on `reply` — enough to make it a well-formed, wire-able, chip-able primitive.
##
## This is a leaf data-carrier at the host floor (like Const). Per the movable-boundary model
## it can later be OPENED into a finer sub-graph (role / content / metadata nodes) via a Chip
## or a typed hole — "what is a primitive" stays changeable.
##
## params:
##   role        "user" | "assistant" | "system" | "idea" | "note" | <human id>
##   content     the text
##   author      "claude" | "claude-code" | "cowork" | <human id> | ""   (who wrote it)
##   created_at  ordering key (unix ms int, or ISO 8601 string) — REQUIRED for a stable
##               linear projection; without it the linear and graph views drift.
##   title       optional short label (used as the semantic-zoom summary)

func _init() -> void:
	prim_type = "Message"

func input_ports() -> Array:
	return [{ "name": "parent", "type": "message" }]

func output_ports() -> Array:
	return [{ "name": "reply", "type": "message" }]

## This node's record as a plain, serializable Dictionary (renderer-neutral).
func record() -> Dictionary:
	return {
		"role": String(params.get("role", "user")),
		"content": String(params.get("content", "")),
		"author": String(params.get("author", "")),
		"created_at": params.get("created_at", 0),
		"title": String(params.get("title", "")),
	}

func evaluate(_inputs: Dictionary) -> Dictionary:
	return { "reply": record() }
