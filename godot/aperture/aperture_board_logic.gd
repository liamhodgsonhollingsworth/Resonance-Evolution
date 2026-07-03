class_name ApertureBoardLogic
extends RefCounted
## PURE-DATA parity core for the 2D GODOT APERTURE BOARD — a line-for-line GDScript duplicate of
## the web board's routing + ordering logic in aperture.js (the SOURCE OF TRUTH at
## repos/Resonance-Website/static/aperture/aperture.js). The point (Liam 2026-07-03, card
## apx_11a5dce2) is CROSS-RENDERER EQUIVALENCE: "an equivalent system that functioned the exact
## same between the two renderers (web and godot) ... to prove that the system neutrality was
## being followed." So every predicate/algorithm here mirrors the JS by name:
##
##   is_decision_artifact   <-> isDecisionArtifact   (aperture.js)
##   is_evolver_candidate   <-> isEvolverCandidate
##   is_notification        <-> isNotificationTile
##   content_type_of        <-> contentTypeOf        (+ the same 4 regexes)
##   disperse_by_type       <-> disperseByType       (deterministic round-robin)
##   interleave_by_category <-> interleaveByCategory
##   hoist_pinned           <-> hoistPinned
##   compose                <-> render()+composeGridTiles (BOARD_CAP, buckets, order)
##   explore_url            <-> exploreUrl           (never-dead-link fallback)
##
## Engine-agnostic data-in/data-out (no scene types) so the 2D board scene, the primitives, and
## the headless parity test share ONE implementation — exactly like ApertureInbox/ApertureActions
## (the read/write halves this file composes with). The headless test cross-checks disperse_by_type
## against the REAL aperture.js functions executed via node, so drift from the web logic FAILS.

# Class-cache-independent sibling load (grey-screen defect, 2026-07-03): resolved by PATH so this
# script parses on checkouts whose gitignored .godot global-class cache is stale or absent (fresh
# clone / pulled-but-never-imported main checkout). See aperture_board_2d.gd for the full note.
const ApertureInbox = preload("res://aperture/aperture_inbox.gd")

## Spec 5 (web): cap the active grid to a readable count. MUST match aperture.js BOARD_CAP.
const BOARD_CAP := 30

## Mirrors aperture.js DECISION_KINDS.
const DECISION_KINDS := ["asset_candidate", "question"]

# The four content-type regexes, verbatim from aperture.js (case-insensitive via (?i)).
const _PAPER_LINK_PATTERN := "(?i)arxiv\\.org|doi\\.org|/abs/|pubmed|biorxiv|ssrn|jstor|\\.pdf(\\?|$)"
const _ART_LINK_PATTERN := "(?i)artstation\\.com|deviantart|behance|dribbble|cara\\.app|pixiv|/fractal"
const _ART_TEXT_PATTERN := "(?i)\\b(concept art|digital art|fractal art|portfolio|artstation|illustrat|painterly)\\b"
const _PLACE_TEXT_PATTERN := "(?i)\\b(cathedral|chapel|temple|tower|castle|palace|cave|causeway|canyon|spring|geopark|national park|mountain|falls|bridge|monument|ruins|abbey|basilica|mosque|shrine|landmark|aurora|danxia|reef|volcano|glacier)\\b"

static var _re_cache: Dictionary = {}

static func _re(pattern: String) -> RegEx:
	if not _re_cache.has(pattern):
		var r := RegEx.new()
		r.compile(pattern)
		_re_cache[pattern] = r
	return _re_cache[pattern]

# ---------------------------------------------------------------------------------------------------
# normalization — inbox rows + board-json tiles into ONE card shape (superset of ApertureInbox's)
# ---------------------------------------------------------------------------------------------------

## Normalize one RAW inbox row (the /api/aperture/inbox artifact object, or an inbox.jsonl row)
## into the card dict the 2D board renders. Wraps ApertureInbox.normalize_card (the shared read
## half) and adds the fields the web client's artifactToTile carries that the 3D surface did not
## need: category, palette_token, pinned, is_notification, skip_id.
static func normalize_row(row: Dictionary) -> Dictionary:
	var card := ApertureInbox.normalize_card(row)
	card["category"] = "artifact"                    # artifactToTile: category "artifact"
	var tok = row.get("palette_token")
	card["palette_token"] = String(tok) if tok != null and String(tok) != "" else "accent.violet"
	card["pinned"] = bool(row.get("pinned")) if row.get("pinned") != null else false
	# isNotificationTile parity: evolver first (never a notification), then the server's explicit
	# boolean. When the boolean is absent (the FILE channel reads raw inbox rows the server never
	# annotated), mirror the SERVER's is_notification_row — the file channel stands in for the
	# server, so it must route exactly as the server would have.
	if is_evolver_candidate(card):
		card["is_notification"] = false
	elif typeof(row.get("is_notification")) == TYPE_BOOL:
		card["is_notification"] = bool(row.get("is_notification"))
	else:
		card["is_notification"] = is_notification_row_mirror(row, card)
	card["skip_id"] = card["id"]                     # pushed artifact → its apx_ id (skipId parity)
	card["source"] = "inbox"
	return card

## Normalize one aperture_board.json tile (the git-tracked curated board) into the same card shape.
static func normalize_board_tile(t: Dictionary) -> Dictionary:
	var images: Array = []
	var multi = t.get("images")
	if typeof(multi) == TYPE_ARRAY:
		for u in multi:
			if u != null and String(u) != "":
				images.append(String(u))
	if images.is_empty() and t.get("image_url") != null and String(t.get("image_url")) != "":
		images.append(String(t.get("image_url")))
	var id := String(t.get("id", ""))
	# skipId parity: board content tile → its source node id, else the "tile_"-stripped id.
	var skip_id := String(t.get("source_node", "")) if t.get("source_node") != null else ""
	if skip_id == "":
		skip_id = id.trim_prefix("tile_artifact_").trim_prefix("tile_")
		if skip_id == "":
			skip_id = id
	return {
		"id": id,
		"kind": String(t.get("kind", "content")),
		"category": String(t.get("category", "other")) if t.get("category") != null else "other",
		"title": String(t.get("title", "")),
		"subtitle": _s(t.get("subtitle")),
		"summary": _s(t.get("summary")),
		"text": "",
		"link": _s(t.get("link_url")),
		"images": images,
		"actions": [],
		"disposition": "content",
		"generation": -1,
		"source_session": "",
		"palette_token": _s(t.get("palette_token")) if _s(t.get("palette_token")) != "" else "accent.cool",
		"pinned": bool(t.get("pinned")) if t.get("pinned") != null else false,
		"is_notification": false,
		"skip_id": skip_id,
		"source": "board",
	}

static func _s(v) -> String:
	return "" if v == null else String(v)

# ---------------------------------------------------------------------------------------------------
# predicates — verbatim ports of the aperture.js routing splits
# ---------------------------------------------------------------------------------------------------

## isDecisionArtifact parity: disposition "decision", a decision kind, or custom actions whose
## id-set differs from the default {approve, reject}.
static func is_decision_artifact(card: Dictionary) -> bool:
	if String(card.get("disposition", "")) == "decision":
		return true
	if String(card.get("kind", "")) in DECISION_KINDS:
		return true
	var ids: Array = []
	for a in card.get("actions", []):
		ids.append(String((a as Dictionary).get("id", "")))
	ids.sort()
	if ids.size() > 0 and not (ids.size() == 2 and ids[0] == "approve" and ids[1] == "reject"):
		return true
	return false

## isEvolverCandidate parity: detection by kind, unambiguous.
static func is_evolver_candidate(card: Dictionary) -> bool:
	return String(card.get("kind", "")) == "evolver_candidate"

## isNotificationTile parity (for already-normalized cards; normalize_row precomputes this).
static func is_notification(card: Dictionary) -> bool:
	if is_evolver_candidate(card):
		return false
	if typeof(card.get("is_notification")) == TYPE_BOOL:
		return bool(card.get("is_notification"))
	return is_decision_artifact(card)

const _NOTIFY_SOURCE_PATTERN := "(?i)coordinator|review|maintainer|system"

static func _flag(v) -> bool:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	return false

## endpoints/_substrate.is_notification_row parity — the server-side routing the file channel
## must reproduce: decision disposition/kind/custom-actions, notify/pin/system flags, the
## preview/review "show-you-this" kinds, and coordinator-ish source sessions.
static func is_notification_row_mirror(row: Dictionary, card: Dictionary) -> bool:
	var kind := String(card.get("kind", "")).strip_edges().to_lower()
	if String(card.get("disposition", "")).strip_edges().to_lower() == "decision":
		return true
	if kind in DECISION_KINDS:
		return true
	if _flag(row.get("notify")) or _flag(row.get("pin")) or _flag(row.get("system")):
		return true
	if kind == "preview" or kind == "review":
		return true
	if _re(_NOTIFY_SOURCE_PATTERN).search(String(card.get("source_session", ""))) != null:
		return true
	var ids: Array = []
	for a in card.get("actions", []):
		ids.append(String((a as Dictionary).get("id", "")))
	ids.sort()
	if ids.size() > 0 and not (ids.size() == 2 and ids[0] == "approve" and ids[1] == "reject"):
		return true
	return false

# ---------------------------------------------------------------------------------------------------
# content-type dispersion — contentTypeOf + disperseByType (Spec 1, verbatim algorithm)
# ---------------------------------------------------------------------------------------------------

static func _tile_text(card: Dictionary) -> String:
	# tileText_ parity: [title, subtitle, summary, media.text, category] joined with " ".
	var parts: Array = []
	for k in ["title", "subtitle", "summary", "text", "category"]:
		var v := String(card.get(k, ""))
		if v != "":
			parts.append(v)
	return " ".join(parts)

## contentTypeOf parity: the five visible buckets — paper / art / place / image / text.
static func content_type_of(card: Dictionary) -> String:
	if card.is_empty():
		return "text"
	var kind := String(card.get("kind", ""))
	if kind == "suggestion" or kind == "quote":
		return "text"
	var link := String(card.get("link", ""))
	var text := _tile_text(card)
	var n_img: int = (card.get("images", []) as Array).size()
	if _re(_PAPER_LINK_PATTERN).search(link) != null:
		return "paper"
	if _re(_ART_LINK_PATTERN).search(link) != null or _re(_ART_TEXT_PATTERN).search(text) != null:
		return "art"
	if n_img >= 2 or _re(_PLACE_TEXT_PATTERN).search(text) != null:
		return "place"
	if n_img == 1:
		return "image"
	return "text"

## disperseByType parity: deterministic round-robin over content-type buckets — bucket by
## content_type_of preserving incoming order, then repeatedly emit from the LARGEST remaining
## bucket, never the same type twice in a row when an alternative exists. Ties break by bucket
## first-seen order (JS Map insertion order + stable Array.sort — reproduced here explicitly,
## because GDScript's sort_custom is not guaranteed stable).
static func disperse_by_type(cards: Array) -> Array:
	return _round_robin(cards, func(c): return content_type_of(c))

## interleaveByCategory parity (the board-tile pass): same algorithm keyed on `category`.
static func interleave_by_category(cards: Array) -> Array:
	return _round_robin(cards, func(c):
		var cat := String((c as Dictionary).get("category", "other"))
		return cat if cat != "" else "other")

## The shared deterministic round-robin core both dispersers use (identical in aperture.js too —
## disperseByType and interleaveByCategory are the same algorithm keyed differently).
static func _round_robin(cards: Array, key_fn: Callable) -> Array:
	if cards.size() <= 2:
		return cards.duplicate()
	var bucket_order: Array = []                 # keys in first-seen order
	var buckets: Dictionary = {}                 # key -> Array of cards (incoming order)
	for c in cards:
		var ty: String = key_fn.call(c)
		if not buckets.has(ty):
			buckets[ty] = []
			bucket_order.append(ty)
		(buckets[ty] as Array).append(c)
	if buckets.size() <= 1:
		return cards.duplicate()
	var out: Array = []
	var last_key := ""
	for i in cards.size():
		# live buckets in (length desc, first-seen asc) order — the stable JS sort result.
		var ranked: Array = []
		for ty in bucket_order:
			if (buckets[ty] as Array).size() > 0:
				ranked.append(ty)
		if ranked.is_empty():
			break
		ranked.sort_custom(func(a, b):
			var la: int = (buckets[a] as Array).size()
			var lb: int = (buckets[b] as Array).size()
			if la != lb:
				return la > lb
			return bucket_order.find(a) < bucket_order.find(b))
		var pick: String = ranked[0]
		for ty in ranked:
			if ty != last_key:
				pick = ty
				break
		out.append((buckets[pick] as Array).pop_front())
		last_key = pick
	return out

## hoistPinned parity: pinned tiles to the FRONT, both relative orders preserved.
static func hoist_pinned(cards: Array) -> Array:
	var pinned: Array = []
	var rest: Array = []
	for c in cards:
		if bool((c as Dictionary).get("pinned", false)):
			pinned.append(c)
		else:
			rest.append(c)
	if pinned.is_empty():
		return cards.duplicate()
	return pinned + rest

# ---------------------------------------------------------------------------------------------------
# composition — render() + composeGridTiles() parity: the three board regions from one input
# ---------------------------------------------------------------------------------------------------

## Split normalized inbox cards (+ optional board-json cards) into the three regions the web board
## renders, in the web board's exact order:
##   evolver       -> the pinned top row (rendered as ONE compact "Evolution — N candidates" entry)
##   notifications -> the full-width top banner (never clipped)
##   grid          -> hoist_pinned(disperse_by_type(capped content artifacts + board tiles))
## `skipped` is a Dictionary-used-as-set of skip_ids (the client's optimistic local set; the
## server/file channel has already filtered durable skips).
static func compose(inbox_cards: Array, board_cards: Array = [], skipped: Dictionary = {}) -> Dictionary:
	var evolver: Array = []
	var notifications: Array = []
	var content: Array = []
	for c in inbox_cards:
		var card: Dictionary = c
		if skipped.has(String(card.get("skip_id", card.get("id", "")))):
			continue
		if is_evolver_candidate(card):
			evolver.append(card)
		elif is_notification(card):
			notifications.append(card)
		else:
			content.append(card)
	var capped := content.slice(0, BOARD_CAP)
	var room: int = max(0, BOARD_CAP - capped.size())
	# initStateFromBoard parity: board tiles are skip-filtered, category-interleaved, capped …
	var btiles: Array = []
	for t in board_cards:
		if not skipped.has(String((t as Dictionary).get("skip_id", ""))):
			btiles.append(t)
	btiles = interleave_by_category(btiles).slice(0, BOARD_CAP)
	# … then composeGridTiles fills the remaining room after the pushed artifacts.
	btiles = btiles.slice(0, room)
	var grid := hoist_pinned(disperse_by_type(capped + btiles))
	return { "evolver": evolver, "notifications": notifications, "grid": grid }

# ---------------------------------------------------------------------------------------------------
# open + image-source helpers
# ---------------------------------------------------------------------------------------------------

## exploreUrl parity: a click ALWAYS reaches an explorable page — the real link when it is a
## proper URL, else a Wikipedia search for the tile's subject. "" when there is no subject at all.
static func explore_url(card: Dictionary) -> String:
	var direct := String(card.get("link", ""))
	if direct.begins_with("http://") or direct.begins_with("https://"):
		return direct
	var subject := String(card.get("title", ""))
	if subject == "":
		subject = String(card.get("subtitle", ""))
	subject = subject.replace("\"", "").replace("“", "").replace("”", "").strip_edges()
	if subject == "":
		return ""
	return "https://en.wikipedia.org/w/index.php?search=" + subject.uri_encode()

## Resolve ONE image reference to a loadable source. The web page loads images through the
## same-origin /api/aperture/media?path=… route for local files; this maps that route BACK to the
## same local file (identical bytes, no server round-trip), keeps http(s) URLs remote, and passes
## plain drive paths through. Returns { "type": "local"|"http"|"none", "path"|"url" }.
static func resolve_image_source(src: String, base_url: String = "http://127.0.0.1:8770") -> Dictionary:
	var u := src.strip_edges()
	if u == "":
		return { "type": "none" }
	if u.begins_with("/api/aperture/media"):
		var qi := u.find("path=")
		if qi >= 0:
			var enc := u.substr(qi + 5)
			var amp := enc.find("&")
			if amp >= 0:
				enc = enc.substr(0, amp)
			var p := enc.uri_decode()
			if p != "":
				return { "type": "local", "path": p }
		return { "type": "http", "url": base_url.rstrip("/") + u }
	if u.begins_with("http://") or u.begins_with("https://"):
		return { "type": "http", "url": u }
	if u.begins_with("/"):
		return { "type": "http", "url": base_url.rstrip("/") + u }
	return { "type": "local", "path": u }
