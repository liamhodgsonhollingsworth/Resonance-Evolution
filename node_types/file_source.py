"""
FileSource — a data-source node-type. Reads a file, applies a named
parser, exposes the normalized item-list on an `items` channel.

Pairs with any renderer-node consuming the `items` channel (ListRenderer
is the first such). The orthogonality is the load-bearing design move:
data sources are interchangeable; renderers are interchangeable; a new
panel = one source-config + one renderer-config + one connection.

FileSource uses `precompute_hook` to do the read+parse work once at
build time and cache the result. emit() reads from the cache, so the
per-frame cost is constant regardless of source file size. The engine's
file-watcher (engine/file_watcher.py) already covers `node_types/` and
`renderers/`; future work wires it to invalidate FileSource caches when
arbitrary source paths change (wishlist #008).

The same primitive composes with the engine's failure isolation: a
broken parser leaves an error message on the items channel instead of
crashing the whole panel — the renderer downstream displays the error
in-place, which is what the maintainer wants for debuggable panels.

Path confinement (SPEC-079 follow-up, 2026-05-20)
-------------------------------------------------

A FileSource resolves its ``path`` to an absolute real-path (symlinks
resolved) and rejects any path NOT inside the allow-list. The
allow-list covers:

- The Apeiron project root.
- Cross-project workspace dirs (``~/Desktop/Apeiron``,
  ``~/Desktop/Alethea``, ``~/Desktop/Resonance``).
- The temp-import zone at ``<apeiron_root>/state/temp_imports/``.
- Any extra roots registered via :func:`add_allowed_root` (tests use
  this to admit ``tmp_path`` without weakening the production check).
- Any roots from the ``APEIRON_FILE_SOURCE_EXTRA_ALLOWED_ROOTS`` env
  var (semicolon-separated; one alternative is one root each).

Rejection raises :class:`FileSourceOutsideAllowListError` at build
time. The engine's spawn() catches the exception and marks the node
``dead`` with the error message, so a malicious paste cannot read an
arbitrary file under cover of the normal precompute path.

Rationale: this gate is the SPEC-073 + SPEC-054 composition fix flagged
by the 2026-05-20 post-compact stress-test. Pasted snippets can name
any path string; without confinement, paste-of-FileSource is a read
primitive against any path the process can reach. After the gate, the
attack surface is the documented allow-list only.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable, List, Set

from engine.node import Channels, EmitContext, Manifest, View
from node_types.parsers import get_parser


# ---------------------------------------------------------------------------
# Path-confinement allow-list.
# ---------------------------------------------------------------------------


class FileSourceOutsideAllowListError(Exception):
    """Raised when a FileSource ``path`` resolves outside the allow-list.

    The exception message names the requested real-path AND the active
    allow-list so the maintainer (or a calling session) can diagnose the
    rejection without re-reading the source. The same message text is
    surfaced via the engine's error log when build() is called inside
    Engine.spawn().
    """


# Process-wide registry of extra roots. Backed by the OS environment so
# every importer of file_source (including the engine's spec-loaded copy
# at ``apeiron_node_types_file_source``) sees the same entries. Tests
# register their ``tmp_path`` here via ``add_allowed_root``; the engine-
# side build() and the test-side direct call both consult the same
# env var when resolving the allow-list.
#
# Marshalling: stored as ``os.pathsep``-separated resolved-path strings
# under ``_APEIRON_FILE_SOURCE_RUNTIME_ALLOW_ROOTS``. The variable name
# is distinct from ``APEIRON_FILE_SOURCE_EXTRA_ALLOWED_ROOTS`` (the
# documented user-facing env var) so the maintainer's static config and
# the runtime registry don't collide.
_RUNTIME_ENV_VAR = "_APEIRON_FILE_SOURCE_RUNTIME_ALLOW_ROOTS"


def _runtime_allowed_roots() -> Set[Path]:
    """Read the runtime registry from the env var. Each call returns a
    fresh set so callers can mutate freely without affecting the source.
    """
    raw = os.environ.get(_RUNTIME_ENV_VAR, "")
    if not raw:
        return set()
    out: Set[Path] = set()
    for entry in raw.split(os.pathsep):
        entry = entry.strip()
        if not entry:
            continue
        try:
            out.add(Path(entry).expanduser().resolve())
        except (OSError, RuntimeError):
            continue
    return out


def _write_runtime_allowed_roots(roots: Set[Path]) -> None:
    if not roots:
        # Delete rather than store an empty string so the env stays clean.
        os.environ.pop(_RUNTIME_ENV_VAR, None)
        return
    os.environ[_RUNTIME_ENV_VAR] = os.pathsep.join(str(p) for p in sorted(roots))


# Backward-compatibility alias so existing references to
# ``_EXTRA_ALLOWED_ROOTS`` (test assertions, external callers) keep
# working. The attribute returns a snapshot of the current registry on
# each access; mutating the returned set has no side effect.
class _ExtraRootsView:
    """A read-only snapshot of the runtime allow-list extras.

    The class exposes set-like membership and iteration so legacy
    code referencing ``_EXTRA_ALLOWED_ROOTS`` keeps working. Mutating
    operations go through ``add_allowed_root`` / ``clear_extra_allowed_roots``.
    """

    def __contains__(self, item) -> bool:
        return Path(item).resolve() in _runtime_allowed_roots()

    def __iter__(self):
        return iter(_runtime_allowed_roots())

    def __len__(self) -> int:
        return len(_runtime_allowed_roots())

    def __eq__(self, other) -> bool:
        try:
            return _runtime_allowed_roots() == frozenset(other)
        except TypeError:
            return NotImplemented

    def __repr__(self) -> str:
        return f"_ExtraRootsView({sorted(_runtime_allowed_roots())!r})"


_EXTRA_ALLOWED_ROOTS = _ExtraRootsView()


def _apeiron_root() -> Path:
    """The Apeiron repo root, resolved once per call.

    FileSource lives at ``<root>/node_types/file_source.py``; the root
    is two parents up. Resolved so symlinked checkouts still produce a
    real-path that other resolved paths can be compared against.
    """
    return Path(__file__).resolve().parent.parent


def _env_allowed_roots() -> Iterable[Path]:
    raw = os.environ.get("APEIRON_FILE_SOURCE_EXTRA_ALLOWED_ROOTS", "")
    if not raw:
        return ()
    out: List[Path] = []
    for entry in raw.split(os.pathsep):
        entry = entry.strip()
        if not entry:
            continue
        try:
            out.append(Path(entry).expanduser().resolve())
        except (OSError, RuntimeError):
            continue
    return out


def _default_allowed_roots() -> List[Path]:
    """The canonical allow-list: project root, cross-project workspace
    dirs, and the temp-import zone. Each root is resolved (symlinks
    followed) so comparison against a resolved candidate is exact.
    """
    apeiron_root = _apeiron_root()
    home = Path.home()
    candidates = [
        apeiron_root,
        apeiron_root / "state" / "temp_imports",
        home / "Desktop" / "Apeiron",
        home / "Desktop" / "Alethea",
        home / "Desktop" / "Resonance",
    ]
    resolved: List[Path] = []
    for c in candidates:
        try:
            r = c.resolve()
        except (OSError, RuntimeError):
            continue
        if r not in resolved:
            resolved.append(r)
    return resolved


def get_allowed_roots() -> List[Path]:
    """Return the active allow-list as a list of resolved absolute paths.

    Order: defaults first, then env-var extras, then runtime-registered
    extras. Duplicates removed while preserving order.
    """
    seen: Set[Path] = set()
    out: List[Path] = []
    for p in _default_allowed_roots():
        if p not in seen:
            seen.add(p)
            out.append(p)
    for p in _env_allowed_roots():
        if p not in seen:
            seen.add(p)
            out.append(p)
    for p in sorted(_runtime_allowed_roots()):
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def add_allowed_root(root) -> None:
    """Register an extra allow-list entry at runtime.

    Tests use this to admit ``tmp_path`` without weakening the
    production default-list. The path is resolved (real-path,
    symlinks followed) before insertion. Empty / unresolvable paths
    are rejected with ``ValueError``.

    The registry is backed by the OS environment so every importer of
    this module — including the engine's spec-loaded copy under a
    distinct module name — sees the same entries. The conftest's
    autouse fixture relies on this cross-module visibility.
    """
    if root is None:
        raise ValueError("add_allowed_root: root must not be None")
    # Reject empty / whitespace BEFORE constructing the Path — Path("")
    # silently becomes a "." reference to the CWD, which would otherwise
    # admit the entire CWD into the allow-list.
    if isinstance(root, str) and not root.strip():
        raise ValueError("add_allowed_root: root must not be empty")
    p = Path(root)
    if not str(p).strip() or str(p) == ".":
        raise ValueError("add_allowed_root: root must be a non-empty path")
    try:
        resolved = p.expanduser().resolve()
    except (OSError, RuntimeError) as exc:
        raise ValueError(f"add_allowed_root: cannot resolve {root!r}: {exc}") from exc
    current = _runtime_allowed_roots()
    current.add(resolved)
    _write_runtime_allowed_roots(current)


def clear_extra_allowed_roots() -> None:
    """Remove every runtime-registered extra root.

    Tests call this in teardown so one test's allow-list doesn't leak
    into the next. The defaults and env-var entries are untouched.
    """
    _write_runtime_allowed_roots(set())


def _is_inside(candidate: Path, root: Path) -> bool:
    """True iff ``candidate`` is ``root`` or any descendant.

    Both arguments must already be resolved (no symlinks). The check is
    purely structural — equality + ``Path.is_relative_to``-equivalent
    (manually computed for compatibility with Python <3.9 in case that
    surfaces). On Windows the comparison is case-insensitive because the
    filesystem treats paths that way.
    """
    try:
        candidate.relative_to(root)
    except ValueError:
        if os.name == "nt":
            # Windows is case-insensitive. Compare normalised string
            # prefixes as a fallback for the relative_to mismatch when
            # case differs across drive-letter vs UNC-style spellings.
            cstr = os.path.normcase(str(candidate))
            rstr = os.path.normcase(str(root))
            if cstr == rstr:
                return True
            return cstr.startswith(rstr + os.sep)
        return False
    return True


def _resolve_and_check(path_str: str) -> Path:
    """Resolve ``path_str`` and verify it falls inside the allow-list.

    Empty / whitespace-only paths are rejected before resolution so the
    error message names the original input (not a CWD-based resolution
    that obscures the cause).

    Relative paths are resolved against the Apeiron project root rather
    than the process CWD — the production CWD varies across sessions
    (worktrees, ad-hoc shells, MCP servers) and a CWD-dependent gate is
    not a gate.

    Symlinks are followed during resolution: the *real* path is what
    gets checked, so a symlink in an allow-listed dir pointing at
    ``C:\\Windows\\System32`` is rejected on the resolved target.
    """
    if path_str is None or not str(path_str).strip():
        roots = get_allowed_roots()
        raise FileSourceOutsideAllowListError(
            "FileSource: path is empty; "
            f"allowed roots: {[str(r) for r in roots]}"
        )
    p = Path(str(path_str)).expanduser()
    if not p.is_absolute():
        p = _apeiron_root() / p
    try:
        resolved = p.resolve(strict=False)
    except (OSError, RuntimeError) as exc:
        raise FileSourceOutsideAllowListError(
            f"FileSource: cannot resolve path {path_str!r}: {exc}; "
            f"allowed roots: {[str(r) for r in get_allowed_roots()]}"
        ) from exc

    # Symlink real-path: if the file IS a symlink, follow it for the
    # security decision. The check rejects when the resolved target is
    # outside the allow-list even though the link itself sits inside.
    real = resolved
    try:
        if resolved.is_symlink():
            real = resolved.readlink()
            if not real.is_absolute():
                real = resolved.parent / real
            real = real.resolve(strict=False)
    except (OSError, RuntimeError):
        # If we can't follow the symlink, treat the resolved path as
        # authoritative — it's still better than a raw user-supplied
        # path, and the actual read will fail later if broken.
        pass

    roots = get_allowed_roots()
    for root in roots:
        if _is_inside(real, root) or _is_inside(resolved, root):
            # Both must be in the allow-list when symlinks differ; if
            # the symlink target is outside, reject.
            if real != resolved and not any(_is_inside(real, r) for r in roots):
                raise FileSourceOutsideAllowListError(
                    f"FileSource: symlink {resolved} points outside allow-list "
                    f"(real-path: {real}); allowed roots: {[str(r) for r in roots]}"
                )
            return resolved
    raise FileSourceOutsideAllowListError(
        f"FileSource: path {resolved} is outside the allow-list "
        f"(real-path: {real}); allowed roots: {[str(r) for r in roots]}"
    )


# ---------------------------------------------------------------------------
# Node-type surface.
# ---------------------------------------------------------------------------


def manifest() -> Manifest:
    return Manifest(
        name="FileSource",
        version="1.0",
        renderer_id="raster",
        inputs={
            "path": "string",
            "parser_name": "string",
        },
        outputs={"items": "list_of_dict", "source_path": "string"},
        description=(
            "Reads a file, applies a named parser, exposes normalized "
            "items on the 'items' channel. Pairs with any renderer that "
            "consumes 'items'."
        ),
    )


def build(params):
    """Validate the params and resolve+confine the path.

    Path confinement runs here so a rejection produces a dead node at
    spawn time rather than letting a malicious path get as far as
    precompute (where a paste-of-FileSource would actually read the
    file). The engine catches the raised exception in spawn() and marks
    the node dead with the same message.

    An empty ``path`` is accepted at build time (the precompute hook
    already reports a clean "required" error message for empty
    parameters). Confinement applies only when a non-empty path is
    supplied — otherwise the canonical default scene's "path required"
    errors flip from informational to security-fatal for no reason.
    """
    raw_path = str(params.get("path", ""))
    parser_name = str(params.get("parser_name", ""))
    resolved_path = ""
    if raw_path.strip():
        resolved = _resolve_and_check(raw_path)
        resolved_path = str(resolved)
    return {
        "path": resolved_path or raw_path,
        "parser_name": parser_name,
        "raw_path": raw_path,
    }


def select_children(state, view: View, engine, node) -> List[str]:
    # Data-source nodes have no graphical children to recurse into.
    return []


def precompute_hook(state, engine, node):
    """Read file + parse once at build time; cache the items list.

    The path was already confined at build() time — this function
    trusts ``state['path']`` and reads it directly. Reaching
    precompute means spawn() accepted the path, so a malicious payload
    can't land here without an allow-list bypass.
    """
    path = state["path"]
    parser_name = state["parser_name"]

    if not path or not parser_name:
        return {"items": [], "error": "FileSource: 'path' and 'parser_name' both required"}

    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"items": [], "error": f"FileSource: file not found at {path}"}
    except OSError as e:
        return {"items": [], "error": f"FileSource: read failed: {e}"}

    try:
        parser = get_parser(parser_name)
    except (ImportError, AttributeError) as e:
        return {"items": [], "error": f"FileSource: parser '{parser_name}' not found ({e})"}

    try:
        items = parser(text)
    except Exception as e:
        return {"items": [], "error": f"FileSource: parser '{parser_name}' failed: {e}"}

    return {"items": items, "error": None}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Empty visual channels; items live in engine.cache, consumed by
    downstream renderer-nodes via ctx.engine.cache[source_node_id]."""
    cache_entry = ctx.engine.cache.get(ctx.node.id, {"items": [], "error": None})
    return {
        "items": cache_entry.get("items", []),
        "source_error": cache_entry.get("error"),
        "source_path": state["path"],
    }


def describe(state, ctx: EmitContext) -> str:
    cache_entry = ctx.engine.cache.get(ctx.node.id, {"items": [], "error": None})
    items = cache_entry.get("items", [])
    err = cache_entry.get("error")
    if err:
        return f"FileSource({state['path']}): error — {err}"
    return (
        f"FileSource(path={state['path']!r}, parser={state['parser_name']!r}, "
        f"items={len(items)})"
    )
