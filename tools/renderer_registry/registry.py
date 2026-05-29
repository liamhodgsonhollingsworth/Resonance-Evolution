"""Renderer-kind registry — Python runtime mirror of renderer_registry.weft.

Schema-version: 1
Filed: 2026-05-29 per MVP plan Wave 2 (Subagent W2-B + W1-B follow-up).
Authored by: session jovial-margulis-52985e in worktree
             C:/Users/Liam/Desktop/Alethea/.claude/worktrees/jovial-margulis-52985e/

This module is the 1:1 Python mirror of renderer_registry.weft. Each Weft node
in the .weft file is implemented as a function/class with the same name + the
same input/output ports. When Weft's batch CLI ships, this module collapses to
a thin loader; until then it IS the runtime. Same hybrid pattern as
`Alethea-cc/tools/temporal_propagation/` and `tools/weavemind_eval/`.

Per skills/weavemind-first.md Exception case 5 ("runtime not yet available").

Reuse posture (per Sophia's dependency-map review): wires through
Apeiron's existing `engine.Engine.discover()` primitives rather than
parallel-implementing a module scanner. Adds the substrate-side virtual
kinds the MVP introduces (window, tasks-list, chat-bubble, 3d-canvas, ...).

The six Weft phases correspond 1:1 to the functions below:
    Phase 1 — ApeironDiscovery     : scan node_types/ + renderers/ via Engine
    Phase 2 — VirtualKindDeclarations : MVP-side kinds (window, tasks-list, ...)
    Phase 3 — BindingMerger        : merge native + virtual, apeiron-wins
    Phase 4 — RegistryValidator    : check composes-references, fail loud
    Phase 5 — RendererLookup       : read-only query surface
    Phase 6 — HotReloadHook        : trigger rebuild on file change

Invocation:
    from tools.renderer_registry.registry import RendererRegistry
    reg = RendererRegistry.build()           # uses Apeiron default root
    binding = reg.resolve("window")           # -> RendererBinding
    kinds = reg.list_kinds()                  # -> [Kind, ...]
    dom_kinds = reg.filter_by_renderer_id("dom")
    composers = reg.filter_by_composes("button")

Module CLI:
    python -m tools.renderer_registry.registry --list
    python -m tools.renderer_registry.registry --resolve window
    python -m tools.renderer_registry.registry --validate
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib.util
import json
import logging
import sys
import time
import traceback
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable

# Apeiron-root resolution: this file lives at
# C:/Users/Liam/Desktop/Apeiron/tools/renderer_registry/registry.py
# so the Apeiron root is two parents up.
APEIRON_ROOT_DEFAULT = Path(__file__).resolve().parents[2]


# ============================================================================
# Type model — equivalent of Weft's port types
# ============================================================================


@dataclass(frozen=True)
class RendererBinding:
    """One row in the registry. Maps a kind to its renderer implementation."""

    kind: str
    module_path: str  # relative-posix; empty for virtual kinds
    module_name: str  # importable name; empty for virtual kinds
    version: str
    renderer_id: str  # "raster" | "dom" | "canvas" | "text" | "ascii" | "data"
    inputs: dict[str, str] = field(default_factory=dict)
    outputs: dict[str, str] = field(default_factory=dict)
    description: str = ""
    load_status: str = "ok"  # "ok" | "broken" | "untrusted" | "virtual"
    composes: tuple[str, ...] = ()  # for virtual kinds: native primitives reused
    source: str = "apeiron_native"  # "apeiron_native" | "mvp_virtual"


@dataclass(frozen=True)
class ValidationError:
    """One row in the validator's error list."""

    kind: str
    error_type: str  # "missing_compose" | "bad_renderer_id" | "duplicate" | "no_manifest"
    detail: str


# ============================================================================
# Phase 2 declaration — MVP-side virtual kinds the registry adds atop discovery
# ============================================================================

# Mirror of renderer_registry.weft Phase 2 VirtualKindDeclarations.
# When the .weft file changes its kinds: block, this dict updates in lockstep.
VIRTUAL_KIND_DECLARATIONS: dict[str, dict[str, Any]] = {
    "window":           {"renderer_id": "dom",    "composes": ("panel_positioner", "group", "key_bindings")},
    "panel":            {"renderer_id": "dom",    "composes": ("panel_positioner",)},
    "tasks-list":       {"renderer_id": "dom",    "composes": ("list_renderer", "idea_queue")},
    "tasks-list-item":  {"renderer_id": "dom",    "composes": ("text_box", "button")},
    "calendar":         {"renderer_id": "dom",    "composes": ("panel_positioner",)},
    "calendar-entry":   {"renderer_id": "dom",    "composes": ("text_box",)},
    "idea-card":        {"renderer_id": "dom",    "composes": ("idea_queue", "dropdown", "bar")},
    "chat-thread":      {"renderer_id": "dom",    "composes": ("chat_interface", "scroll_bar")},
    "chat-bubble":      {"renderer_id": "dom",    "composes": ("chat_interpreter",)},
    "paste-target":     {"renderer_id": "dom",    "composes": ("panel_positioner",)},
    "palette-item":     {"renderer_id": "dom",    "composes": ("button",)},
    "wire":             {"renderer_id": "dom",    "composes": ()},
    "right-click-menu": {"renderer_id": "dom",    "composes": ("button", "panel_positioner")},
    "workspace":        {"renderer_id": "dom",    "composes": ("panel_positioner",)},
    "3d-canvas":        {"renderer_id": "canvas", "composes": ("computer",)},
    "render-bundle":    {"renderer_id": "data",   "composes": ()},
    "painterly-output": {"renderer_id": "canvas", "composes": ("painterly_post_processor",)},
    "camera":           {"renderer_id": "canvas", "composes": ("computer",)},
    "viewer-state":     {"renderer_id": "data",   "composes": ()},
    "planned-node":     {"renderer_id": "dom",    "composes": ()},
    "sci-fi-node":      {"renderer_id": "dom",    "composes": ()},
    "renderer-node":    {"renderer_id": "dom",    "composes": ()},
}

RENDERER_ID_ALLOWLIST: frozenset[str] = frozenset(
    [
        # Web/MVP-facing
        "dom",       # HTML DOM projection (MVP website)
        "canvas",    # HTML5 <canvas> (3D-canvas, painterly-output)
        "data",      # no visual projection — substrate-only node
        # Apeiron-native renderer categories
        "raster",    # bundle-channel raster (color + depth + ids + normal)
        "text",      # text-shaped channel (LLM-facing renderer)
        "ascii",     # ASCII-debug output (depth-channel projection)
        "logic",     # side-effecting non-visual node (sessions, scene_mutator, panel_positioner)
        "projector_n",  # N-D projector (Apeiron's dimension_n)
        "streamlit-panel",  # Streamlit-host node
    ]
)


# ============================================================================
# Weft node — Phase 1 — ApeironDiscovery -> (bindings: List[RendererBinding])
# ============================================================================


def _kind_from_manifest_name(name: str) -> str:
    """Apeiron manifests use PascalCase names; substrate uses snake_case/kebab.

    The registry is the bridge. The MVP plan v2's dependency spreadsheet
    refers to Apeiron primitives by short names (`apeiron.button`,
    `apeiron.text_box`, etc.). This converter matches that convention:

        ButtonNode      -> button       (strip trailing "Node")
        TextBoxNode     -> text_box     (strip trailing "Node", snake_case)
        PanelPositioner -> panel_positioner
        WorkflowView    -> workflow_view
        Cube            -> cube
        IdeaQueue       -> idea_queue
        MCPSource       -> mcp_source   (consecutive-uppercase preserved)
        DimensionN      -> dimension_n
        ChatRouter      -> chat_router

    Trailing "Node" is dropped because Apeiron's convention is to suffix
    UI primitives with Node (ButtonNode, TextBoxNode) but the substrate's
    canonical short-form (per the dependency spreadsheet) omits it.
    """
    if not name:
        return ""
    # Strip trailing "Node" if it's a suffix and not the whole name
    if name.endswith("Node") and len(name) > 4:
        name = name[:-4]
    out: list[str] = []
    for i, ch in enumerate(name):
        if ch.isupper() and i > 0:
            prev = name[i - 1]
            # Insert underscore before an uppercase letter when the previous
            # char is lowercase (camelCase boundary). Also when transitioning
            # from a run of uppercase letters into a Cap+lower sequence
            # (MCPSource: ...P|S| -> mcp_source).
            if prev.islower():
                out.append("_")
            elif (
                i + 1 < len(name)
                and name[i + 1].islower()
                and prev.isupper()
            ):
                out.append("_")
        out.append(ch.lower())
    return "".join(out)


def ApeironDiscovery(apeiron_root: Path) -> list[RendererBinding]:
    """Phase 1 — scan node_types/ + renderers/ + bind every manifest.

    Wires through `engine.Engine.discover()` per Sophia's reuse-first directive.
    Falls back to a standalone scanner if the engine import fails (so the
    registry remains usable even from contexts where Apeiron isn't on the path).
    """
    log = logging.getLogger("ApeironDiscovery")

    # Reuse path: try to import + drive engine.Engine.discover().
    try:
        sys.path.insert(0, str(apeiron_root))
        from engine.core import Engine
        engine = Engine(root_dir=apeiron_root)
        engine.discover()
        bindings: list[RendererBinding] = []
        for type_name, module in engine.types.items():
            try:
                m = module.manifest()
                source_path = engine.type_sources.get(type_name, "")
                kind_snake = _kind_from_manifest_name(type_name)
                bindings.append(
                    RendererBinding(
                        kind=kind_snake,
                        module_path=source_path,
                        module_name=module.__name__,
                        version=getattr(m, "version", "1.0"),
                        renderer_id=getattr(m, "renderer_id", "raster"),
                        inputs=dict(getattr(m, "inputs", {}) or {}),
                        outputs=dict(getattr(m, "outputs", {}) or {}),
                        description=getattr(m, "description", ""),
                        load_status="ok",
                        composes=(),
                        source="apeiron_native",
                    )
                )
            except Exception as e:
                log.warning("manifest read failed for %s: %s", type_name, e)
        log.info("ApeironDiscovery: discovered %d native kinds via engine", len(bindings))
        return bindings
    except Exception as e:
        log.warning("engine-driven discovery failed (%s); falling back to standalone scanner", e)
        return _standalone_scan(apeiron_root)


def _standalone_scan(apeiron_root: Path) -> list[RendererBinding]:
    """Fallback scanner — used when the engine import is unavailable.

    Same shape as the engine path: walks node_types/ + renderers/, calls
    manifest() on every module. Slightly more defensive (each module gets
    its own try/except so one bad module doesn't break the whole scan).
    """
    log = logging.getLogger("ApeironDiscovery.standalone")
    bindings: list[RendererBinding] = []
    for subdir in ("node_types", "renderers"):
        d = apeiron_root / subdir
        if not d.is_dir():
            continue
        for py_file in sorted(d.glob("*.py")):
            if py_file.name.startswith("_"):
                continue
            try:
                spec = importlib.util.spec_from_file_location(
                    f"apeiron_{subdir}_{py_file.stem}", py_file
                )
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                if not hasattr(module, "manifest"):
                    continue
                m = module.manifest()
                kind_snake = _kind_from_manifest_name(getattr(m, "name", py_file.stem))
                rel = py_file.resolve().relative_to(apeiron_root.resolve()).as_posix()
                bindings.append(
                    RendererBinding(
                        kind=kind_snake,
                        module_path=rel,
                        module_name=module.__name__,
                        version=getattr(m, "version", "1.0"),
                        renderer_id=getattr(m, "renderer_id", "raster"),
                        inputs=dict(getattr(m, "inputs", {}) or {}),
                        outputs=dict(getattr(m, "outputs", {}) or {}),
                        description=getattr(m, "description", ""),
                        load_status="ok",
                        composes=(),
                        source="apeiron_native",
                    )
                )
            except Exception as e:
                log.warning("standalone scan failed for %s: %s", py_file.name, e)
    log.info("ApeironDiscovery.standalone: discovered %d native kinds", len(bindings))
    return bindings


# ============================================================================
# Weft node — Phase 2 — VirtualKindDeclarations -> virtuals: List[RendererBinding]
# ============================================================================


def VirtualKindDeclarations() -> list[RendererBinding]:
    """Phase 2 — MVP-side renderer kinds not yet backed by Apeiron modules.

    These are the kinds the website's renderer pipeline must serve but that
    don't yet exist as Apeiron .py files (`window`, `tasks-list`, `chat-
    bubble`, etc.). Each declaration names the native primitives it composes;
    the validator enforces that every reference resolves.
    """
    out: list[RendererBinding] = []
    for kind, decl in VIRTUAL_KIND_DECLARATIONS.items():
        out.append(
            RendererBinding(
                kind=kind,
                module_path="",
                module_name="",
                version="1.0",
                renderer_id=decl["renderer_id"],
                inputs={},
                outputs={},
                description=f"MVP virtual kind composing {', '.join(decl['composes'])}" if decl["composes"] else "MVP virtual kind",
                load_status="virtual",
                composes=tuple(decl["composes"]),
                source="mvp_virtual",
            )
        )
    return out


# ============================================================================
# Weft node — Phase 3 — BindingMerger -> registry: Map[Kind, RendererBinding]
# ============================================================================


def BindingMerger(
    native: list[RendererBinding], virtual: list[RendererBinding]
) -> dict[str, RendererBinding]:
    """Phase 3 — merge native + virtual; apeiron-native wins on collision.

    The substrate cannot mask a native module — if `cube` is both a discovered
    Apeiron primitive and a virtual MVP declaration, the Apeiron module wins.
    This keeps the substrate honest about what's a real, executable primitive
    vs. a substrate-only render shape.
    """
    registry: dict[str, RendererBinding] = {}
    for binding in native:
        registry[binding.kind] = binding
    for binding in virtual:
        # native wins
        if binding.kind in registry and registry[binding.kind].source == "apeiron_native":
            continue
        registry[binding.kind] = binding
    return registry


# ============================================================================
# Weft node — Phase 4 — RegistryValidator -> (valid, errors)
# ============================================================================


def RegistryValidator(
    registry: dict[str, RendererBinding]
) -> tuple[dict[str, RendererBinding], list[ValidationError]]:
    """Phase 4 — validate composes-references + renderer_id categories.

    Two checks:
        a) every renderer_id must be one of the allowed categories
        b) every virtual binding's composes-reference must resolve to a
           kind in the registry (else it'd be a dangling pointer)

    Failures are surfaced as a structured list. The valid subset is what the
    lookup interface reads through; broken rows are excluded but visible.
    """
    errors: list[ValidationError] = []
    valid: dict[str, RendererBinding] = {}

    for kind, binding in registry.items():
        # Check renderer_id allowlist
        if binding.renderer_id not in RENDERER_ID_ALLOWLIST:
            errors.append(
                ValidationError(
                    kind=kind,
                    error_type="bad_renderer_id",
                    detail=f"renderer_id {binding.renderer_id!r} not in {sorted(RENDERER_ID_ALLOWLIST)}",
                )
            )
            continue

        # For virtual bindings, every compose-reference must resolve
        if binding.source == "mvp_virtual":
            bad_refs = [r for r in binding.composes if r not in registry]
            if bad_refs:
                errors.append(
                    ValidationError(
                        kind=kind,
                        error_type="missing_compose",
                        detail=f"composes references unknown kind(s): {bad_refs}",
                    )
                )
                continue

        valid[kind] = binding

    return valid, errors


# ============================================================================
# Weft node — Phase 5 — RendererLookup (the read-only query surface)
# ============================================================================


@dataclass
class RendererRegistry:
    """Phase 5 — the read-only query surface downstream consumers read.

    Wraps the registry dict + the error list + a snapshot timestamp. Pure
    queries (resolve, list_kinds, filter_by_renderer_id, filter_by_composes);
    rebuilding mutates the snapshot atomically (constructs a new dict +
    swaps it in, so in-flight queries finish against the old snapshot).
    """

    _registry: dict[str, RendererBinding]
    _errors: list[ValidationError]
    _last_rebuild_at: float

    @property
    def errors(self) -> list[ValidationError]:
        """Validation errors from the last rebuild. Empty when clean."""
        return list(self._errors)

    @property
    def last_rebuild_at(self) -> float:
        """Unix timestamp of the last rebuild (for hot-reload diagnostics)."""
        return self._last_rebuild_at

    @property
    def kinds_count(self) -> int:
        return len(self._registry)

    def resolve(self, kind: str) -> RendererBinding | None:
        """Look up a single kind. Returns None if unknown."""
        return self._registry.get(kind)

    def is_registered(self, kind: str) -> bool:
        """True iff the kind has a binding in the registry."""
        return kind in self._registry

    def list_kinds(self) -> list[str]:
        """Every registered kind, sorted alphabetically."""
        return sorted(self._registry.keys())

    def filter_by_renderer_id(self, renderer_id: str) -> list[str]:
        """Every kind whose renderer_id matches."""
        return sorted(
            k for k, b in self._registry.items() if b.renderer_id == renderer_id
        )

    def filter_by_composes(self, native_kind: str) -> list[str]:
        """Every virtual kind that names `native_kind` in its composes list."""
        return sorted(
            k for k, b in self._registry.items()
            if native_kind in b.composes
        )

    def as_dict(self) -> dict[str, dict[str, Any]]:
        """Serialize the registry for JSON / inbox-post / inspection."""
        return {
            k: {
                "kind": b.kind,
                "module_path": b.module_path,
                "module_name": b.module_name,
                "version": b.version,
                "renderer_id": b.renderer_id,
                "inputs": b.inputs,
                "outputs": b.outputs,
                "description": b.description,
                "load_status": b.load_status,
                "composes": list(b.composes),
                "source": b.source,
            }
            for k, b in self._registry.items()
        }

    # ----- Phase 6 hot-reload interface -----

    def rebuild(self, apeiron_root: Path | None = None) -> tuple[int, list[str]]:
        """Phase 6 — rebuild the registry; return (kinds_count, changed_kinds).

        Called by the hot-reload hook when a backing module changes on disk
        or the substrate's virtual-kind declaration is edited. Constructs a
        new snapshot and swaps it in; in-flight queries finish against the
        old snapshot.
        """
        if apeiron_root is None:
            apeiron_root = APEIRON_ROOT_DEFAULT
        old_kinds = set(self._registry.keys())
        native = ApeironDiscovery(apeiron_root)
        virtual = VirtualKindDeclarations()
        merged = BindingMerger(native, virtual)
        valid, errors = RegistryValidator(merged)
        self._registry = valid
        self._errors = errors
        self._last_rebuild_at = time.time()
        new_kinds = set(valid.keys())
        changed = sorted((old_kinds ^ new_kinds))
        return len(valid), changed

    # ----- factory -----

    @classmethod
    def build(cls, apeiron_root: Path | None = None) -> "RendererRegistry":
        """Construct + populate a fresh registry."""
        if apeiron_root is None:
            apeiron_root = APEIRON_ROOT_DEFAULT
        native = ApeironDiscovery(apeiron_root)
        virtual = VirtualKindDeclarations()
        merged = BindingMerger(native, virtual)
        valid, errors = RegistryValidator(merged)
        return cls(
            _registry=valid,
            _errors=errors,
            _last_rebuild_at=time.time(),
        )

    @classmethod
    def empty(cls) -> "RendererRegistry":
        """Empty registry for tests that want to populate manually."""
        return cls(_registry={}, _errors=[], _last_rebuild_at=time.time())

    def _set_for_test(self, registry: dict[str, RendererBinding]) -> None:
        """Test helper — replace the registry contents directly."""
        self._registry = registry
        self._last_rebuild_at = time.time()


# ============================================================================
# Module-level singleton — built lazily on first access
# ============================================================================

_REGISTRY_INSTANCE: RendererRegistry | None = None


def get_registry(apeiron_root: Path | None = None) -> RendererRegistry:
    """Return the process-wide registry, building it on first call.

    Drag-drop dispatcher + node-renderer + paste-target spawn all read
    through this — the registry is a single source of truth per process.
    """
    global _REGISTRY_INSTANCE
    if _REGISTRY_INSTANCE is None:
        _REGISTRY_INSTANCE = RendererRegistry.build(apeiron_root)
    return _REGISTRY_INSTANCE


def reset_registry() -> None:
    """Drop the singleton — next get_registry() rebuilds. Used by tests."""
    global _REGISTRY_INSTANCE
    _REGISTRY_INSTANCE = None


# ============================================================================
# CLI
# ============================================================================


def _main(argv: list[str] | None = None) -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(name)s: %(message)s"
    )
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0] if __doc__ else "")
    parser.add_argument("--list", action="store_true", help="List every registered kind.")
    parser.add_argument("--resolve", metavar="KIND", help="Resolve one kind.")
    parser.add_argument("--validate", action="store_true", help="Report any validation errors.")
    parser.add_argument("--by-renderer-id", metavar="ID", help="Kinds with this renderer_id.")
    parser.add_argument("--by-composes", metavar="NATIVE", help="Kinds composing this native primitive.")
    parser.add_argument("--apeiron-root", type=Path, default=APEIRON_ROOT_DEFAULT)
    parser.add_argument("--json", action="store_true", help="Dump full registry as JSON.")
    args = parser.parse_args(argv)

    reg = RendererRegistry.build(args.apeiron_root)

    if args.validate:
        if not reg.errors:
            print(f"OK: {reg.kinds_count} kinds, no errors")
            return 0
        print(f"ERRORS: {len(reg.errors)} validation issues:")
        for e in reg.errors:
            print(f"  [{e.error_type}] {e.kind}: {e.detail}")
        return 1

    if args.list:
        for kind in reg.list_kinds():
            b = reg.resolve(kind)
            assert b is not None
            tag = f"[{b.source}/{b.renderer_id}]"
            print(f"  {kind:25s} {tag:25s} v{b.version}")
        print(f"\nTotal: {reg.kinds_count} kinds")
        return 0

    if args.resolve:
        b = reg.resolve(args.resolve)
        if b is None:
            print(f"unknown kind: {args.resolve}")
            print(f"available kinds: {', '.join(reg.list_kinds()[:10])}...")
            return 1
        print(json.dumps(reg.as_dict()[args.resolve], indent=2))
        return 0

    if args.by_renderer_id:
        kinds = reg.filter_by_renderer_id(args.by_renderer_id)
        print(f"{len(kinds)} kinds with renderer_id={args.by_renderer_id}:")
        for k in kinds:
            print(f"  {k}")
        return 0

    if args.by_composes:
        kinds = reg.filter_by_composes(args.by_composes)
        print(f"{len(kinds)} virtual kinds composing {args.by_composes!r}:")
        for k in kinds:
            print(f"  {k}")
        return 0

    if args.json:
        print(json.dumps(reg.as_dict(), indent=2))
        return 0

    # Default action: validate + summarize
    print(f"Registry: {reg.kinds_count} kinds")
    print(f"  native (apeiron): {len(reg.filter_by_renderer_id('raster'))} raster + others")
    print(f"  virtual (MVP):    {sum(1 for k in reg.list_kinds() if reg.resolve(k).source == 'mvp_virtual')}")
    print(f"  errors:           {len(reg.errors)}")
    if reg.errors:
        for e in reg.errors[:5]:
            print(f"    [{e.error_type}] {e.kind}: {e.detail}")
        if len(reg.errors) > 5:
            print(f"    ... and {len(reg.errors) - 5} more")
    return 0


if __name__ == "__main__":
    sys.exit(_main())
