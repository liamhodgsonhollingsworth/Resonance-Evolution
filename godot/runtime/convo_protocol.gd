class_name ConvoProtocol
extends RefCounted
## The graph<->text PROTOCOL — the substrate-independent integration core. Pure DATA in ->
## DATA / text out (imports no Godot UI / render type), so the local MCP server, the
## copy-paste bridge, the linear view, and any future web delegate all reuse it verbatim.
## Every transport (Claude Code stdio, remote connector, paste-the-link, copy-paste) is a
## dumb delegate over THIS. Two directions:
##
##   FORWARD  (graph -> text): assemble context from a selected path/subgraph for an LLM, as
##            an alternating role/content array (linear) or an <idea_graph> block (structure).
##   BACKWARD (text -> graph): interpret a fenced `resonance-actions` JSON block from a reply
##            into typed, validated, APPROVAL-GATED action proposals; apply() COMMITS them as
##            a NEW arrangement (append-only). Nothing is auto-applied — apply() is the gate.
##
## A conversation edge is a wire A.reply -> B.parent. A node with several incoming parent
## wires is a MERGE. Context = the de-duplicated union of the selected nodes' ancestors (plus
## the nodes themselves), ordered by created_at. This is ericmjl Canvas Chat's getAncestors /
## resolveContext, reimplemented over the arrangement substrate (algorithm reused, not code).

const PARENT_PORT := "parent"
const REPLY_PORT := "reply"
const ACTIONS_TAG := "resonance-actions"
const ALLOWED_OPS := ["add_node", "wire", "set_active_tip"]

# --- FORWARD: graph -> context -------------------------------------------------------------

## Direct parents of a node: the `from` of every wire (to==id, in==parent).
static func parents_of(arr: Dictionary, id: String) -> Array:
	var out := []
	for w in arr.get("wires", []):
		if String(w.get("to")) == id and String(w.get("in")) == PARENT_PORT:
			out.append(String(w.get("from")))
	return out

## All ancestors of id (excluding id), DFS over parent wires, visited-set dedup + cycle-safe.
static func ancestors(arr: Dictionary, id: String) -> Array:
	var seen := {}
	var stack: Array = parents_of(arr, id).duplicate()
	var result := []
	while not stack.is_empty():
		var p: String = stack.pop_back()
		if seen.has(p):
			continue
		seen[p] = true
		result.append(p)
		for gp in parents_of(arr, p):
			if not seen.has(gp):
				stack.append(gp)
	return result

## The context node SPECS for the selected ids: union of their ancestors + the ids
## themselves, de-duplicated, ordered by created_at then id. Returns Array of node dicts.
static func context_nodes(arr: Dictionary, selected: Array) -> Array:
	var want := {}
	for id in selected:
		want[String(id)] = true
		for a in ancestors(arr, String(id)):
			want[a] = true
	var by_id := _index(arr)
	var picked := []
	for id in want.keys():
		if by_id.has(id):
			picked.append(by_id[id])
	picked.sort_custom(func(x, y): return ConvoProtocol._before(x, y))
	return picked

## Alternating-ish role/content array (the LINEAR projection / message-array context). Roles
## come straight from node params; the API TRANSPORT (Phase D/F) enforces "first is user /
## roles alternate" and folds `system` into the system param — for the copy-paste/text
## methods strict alternation is irrelevant.
static func to_messages(arr: Dictionary, selected: Array) -> Array:
	var out := []
	for n in context_nodes(arr, selected):
		var p: Dictionary = n.get("params", {})
		out.append({ "role": String(p.get("role", "user")), "content": String(p.get("content", "")) })
	return out

## Structure mode: an <idea_graph> block (context-at-top), optional question appended after
## (query-at-bottom — Anthropic's hierarchical-context guidance). Each node carries its id,
## role, in-context parents, and content. DAG-safe: every node is emitted once.
static func to_xml(arr: Dictionary, selected: Array, question := "") -> String:
	var ctx := context_nodes(arr, selected)
	var ctx_ids := {}
	for n in ctx:
		ctx_ids[String(n.get("id"))] = true
	var lines := ["<idea_graph>"]
	for n in ctx:
		var id := String(n.get("id"))
		var p: Dictionary = n.get("params", {})
		var role := String(p.get("role", "user"))
		var ps: Array = parents_of(arr, id).filter(func(x): return ctx_ids.has(x))
		var parent_attr := (" parents=\"%s\"" % ",".join(PackedStringArray(ps))) if not ps.is_empty() else ""
		lines.append("  <node id=\"%s\" role=\"%s\"%s>" % [_esc(id), _esc(role), parent_attr])
		lines.append("    <content>%s</content>" % _esc(String(p.get("content", ""))))
		lines.append("  </node>")
	lines.append("</idea_graph>")
	if question != "":
		lines.append("")
		lines.append(question)
	return "\n".join(PackedStringArray(lines))

## The copy-paste bridge (zero infrastructure, any Claude surface): the text a user pastes
## into claude.ai — the assembled structure + question + a short instruction telling Claude
## how to propose graph edits back as a fenced block that interpret_reply() can parse.
static func to_prompt(arr: Dictionary, selected: Array, question := "") -> String:
	var instr := "\n\nIf you want to add to this idea graph, end your reply with a fenced "
	instr += "```%s block containing a JSON array of actions. " % ACTIONS_TAG
	instr += "Allowed ops: add_node {kind:\"Message\", params:{role, content, author, created_at}, parent:\"<node id>\"}; "
	instr += "wire {from, out:\"reply\", to, in:\"parent\"}; set_active_tip {node}. "
	instr += "Reference existing nodes by their id; do not invent ids for existing nodes."
	return to_xml(arr, selected, question) + instr

# --- BACKWARD: reply text -> graph actions -------------------------------------------------

## Extract + validate the `resonance-actions` JSON block from a reply. Returns
## { "actions": [validated ...], "errors": [strings] }. NOTHING is applied here — this only
## produces PROPOSALS; apply() is the explicit, approval-gated commit.
static func interpret_reply(text: String) -> Dictionary:
	var block := _extract_fenced(text, ACTIONS_TAG)
	if block == "":
		return { "actions": [], "errors": ["no ```%s block found" % ACTIONS_TAG] }
	var parsed = JSON.parse_string(block)
	if typeof(parsed) != TYPE_ARRAY:
		return { "actions": [], "errors": ["%s block is not a JSON array" % ACTIONS_TAG] }
	var actions := []
	var errors := []
	for a in parsed:
		if typeof(a) != TYPE_DICTIONARY:
			errors.append("action is not an object: %s" % str(a))
			continue
		var op := String((a as Dictionary).get("op", ""))
		if not ALLOWED_OPS.has(op):
			errors.append("unknown op '%s' (allowed: %s)" % [op, ", ".join(PackedStringArray(ALLOWED_OPS))])
			continue
		actions.append(a)
	return { "actions": actions, "errors": errors }

## Apply validated actions to produce a NEW arrangement (append-only; input untouched).
##   add_node {kind, params, parent?}  -> a new node (+ a reply->parent wire if parent given)
##   wire     {from, out?, to, in?}    -> a new wire (defaults reply -> parent)
##   set_active_tip {node}             -> sets the top-level current_node pointer
static func apply(arr: Dictionary, actions: Array) -> Dictionary:
	var out := arr.duplicate(true)
	if not out.has("nodes"):
		out["nodes"] = []
	if not out.has("wires"):
		out["wires"] = []
	var nodes: Array = out["nodes"]
	var wires: Array = out["wires"]
	for a in actions:
		match String(a.get("op", "")):
			"add_node":
				var id := _unique_id(out, String(a.get("id", _gen_id(a))))
				nodes.append({ "id": id, "type": String(a.get("kind", "Message")), "params": a.get("params", {}) })
				var parent = a.get("parent", null)
				if parent != null and String(parent) != "":
					wires.append({ "from": String(parent), "out": REPLY_PORT, "to": id, "in": PARENT_PORT })
			"wire":
				wires.append({
					"from": String(a.get("from")), "out": String(a.get("out", REPLY_PORT)),
					"to": String(a.get("to")), "in": String(a.get("in", PARENT_PORT)),
				})
			"set_active_tip":
				out["current_node"] = String(a.get("node"))
	return out

# --- internals -----------------------------------------------------------------------------

static func _before(x: Dictionary, y: Dictionary) -> bool:
	var cx = (x.get("params", {}) as Dictionary).get("created_at", 0)
	var cy = (y.get("params", {}) as Dictionary).get("created_at", 0)
	var nx := typeof(cx) == TYPE_INT or typeof(cx) == TYPE_FLOAT
	var ny := typeof(cy) == TYPE_INT or typeof(cy) == TYPE_FLOAT
	if nx and ny:
		if float(cx) != float(cy):
			return float(cx) < float(cy)
	else:
		var sx := str(cx)
		var sy := str(cy)
		if sx != sy:
			return sx < sy
	return String(x.get("id")) < String(y.get("id"))

static func _index(arr: Dictionary) -> Dictionary:
	var by_id := {}
	for n in arr.get("nodes", []):
		by_id[String(n.get("id"))] = n
	return by_id

static func _extract_fenced(text: String, tag: String) -> String:
	var fence := "```" + tag
	var start := text.find(fence)
	if start == -1:
		return ""
	var nl := text.find("\n", start + fence.length())
	if nl == -1:
		return ""
	var body_start := nl + 1
	var end := text.find("```", body_start)
	if end == -1:
		return ""
	return text.substr(body_start, end - body_start).strip_edges()

static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

static func _unique_id(arr: Dictionary, base: String) -> String:
	var existing := {}
	for n in arr.get("nodes", []):
		existing[String(n.get("id"))] = true
	if base != "" and not existing.has(base):
		return base
	var stem := base if base != "" else "msg"
	var i := 1
	while existing.has("%s_%d" % [stem, i]):
		i += 1
	return "%s_%d" % [stem, i]

static func _gen_id(a: Dictionary) -> String:
	var p: Dictionary = a.get("params", {})
	var seed := String(p.get("role", "msg")) + ":" + String(p.get("content", ""))
	return "msg_" + seed.sha256_text().substr(0, 8)
