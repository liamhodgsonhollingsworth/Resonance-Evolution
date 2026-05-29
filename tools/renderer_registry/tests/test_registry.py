"""Adversarial tests for the renderer-kind registry.

Schema-version: 1
Filed: 2026-05-29 per MVP plan Wave 2.

Coverage: discovery → virtual-declarations → merge → validation → lookup
+ hot-reload semantics + every reuse handle from the dependency spreadsheet.

Invocation (from Apeiron root):
    pytest tools/renderer_registry/tests/test_registry.py -v
    python -m tools.renderer_registry.registry --validate
"""

from __future__ import annotations

import sys
from pathlib import Path

# Apeiron root is two parents up from this file.
APEIRON_ROOT = Path(__file__).resolve().parents[3]
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

import pytest

from tools.renderer_registry.registry import (
    ApeironDiscovery,
    BindingMerger,
    RegistryValidator,
    RendererBinding,
    RendererRegistry,
    VIRTUAL_KIND_DECLARATIONS,
    ValidationError,
    VirtualKindDeclarations,
    RENDERER_ID_ALLOWLIST,
    _kind_from_manifest_name,
    get_registry,
    reset_registry,
)


# ============================================================================
# Discovery tests
# ============================================================================


class TestApeironDiscovery:
    def test_discovery_finds_native_kinds(self):
        """Engine discovery should find the canonical primitives every MVP wave depends on."""
        bindings = ApeironDiscovery(APEIRON_ROOT)
        kinds = {b.kind for b in bindings}
        # The MVP plan dependency spreadsheet lists these as load-bearing
        # reuse targets. If any are missing, the spreadsheet's reuse claims
        # become false and many subsystem estimates need to be revisited.
        required = {
            "cube", "sphere", "plane", "group", "portal", "light",
            "button", "text_box", "slider", "dropdown", "scroll_bar", "bar",
            "panel_positioner", "toolbox", "list_renderer", "idea_queue",
            "chat_interface", "chat_interpreter", "chat_router",
            "computer", "scene_loader", "scene_mutator",
            "file_source", "key_bindings", "browser_renderer",
        }
        missing = required - kinds
        assert not missing, f"discovery missing required Apeiron kinds: {sorted(missing)}"

    def test_each_binding_has_a_manifest_field(self):
        """Every discovered binding must carry a renderer_id + version."""
        bindings = ApeironDiscovery(APEIRON_ROOT)
        assert bindings, "discovery returned zero bindings — environment problem"
        for b in bindings:
            assert b.kind, f"binding {b!r} has empty kind"
            assert b.renderer_id, f"binding {b.kind} has empty renderer_id"
            assert b.version, f"binding {b.kind} has empty version"
            assert b.source == "apeiron_native"

    def test_kind_name_conversion(self):
        """PascalCase manifest names map to snake_case kinds with Node-suffix stripped."""
        # Simple PascalCase
        assert _kind_from_manifest_name("Cube") == "cube"
        assert _kind_from_manifest_name("Sphere") == "sphere"
        # Multi-word PascalCase
        assert _kind_from_manifest_name("PanelPositioner") == "panel_positioner"
        assert _kind_from_manifest_name("WorkflowView") == "workflow_view"
        assert _kind_from_manifest_name("IdeaQueue") == "idea_queue"
        # Trailing "Node" suffix is stripped (Apeiron convention)
        assert _kind_from_manifest_name("ButtonNode") == "button"
        assert _kind_from_manifest_name("TextBoxNode") == "text_box"
        assert _kind_from_manifest_name("SliderNode") == "slider"
        assert _kind_from_manifest_name("DropdownNode") == "dropdown"
        assert _kind_from_manifest_name("ScrollBarNode") == "scroll_bar"
        assert _kind_from_manifest_name("BarNode") == "bar"
        # All-uppercase runs (MCP, etc.)
        assert _kind_from_manifest_name("MCPSource") == "mcp_source"
        # Empty input
        assert _kind_from_manifest_name("") == ""


# ============================================================================
# Virtual-kind declaration tests
# ============================================================================


class TestVirtualKinds:
    def test_every_mvp_kind_is_declared(self):
        """The MVP plan v2 names these renderer kinds — every one must be declared."""
        declared = set(VIRTUAL_KIND_DECLARATIONS.keys())
        required = {
            "window", "panel", "tasks-list", "tasks-list-item",
            "calendar", "calendar-entry", "idea-card",
            "chat-thread", "chat-bubble", "paste-target",
            "3d-canvas", "render-bundle", "painterly-output",
            "camera", "viewer-state", "right-click-menu",
            "palette-item", "wire", "workspace",
            "planned-node", "sci-fi-node", "renderer-node",
        }
        missing = required - declared
        assert not missing, f"MVP plan kinds not declared: {sorted(missing)}"

    def test_virtual_kinds_have_valid_renderer_ids(self):
        """Every virtual kind's renderer_id must be in the allowlist."""
        for kind, decl in VIRTUAL_KIND_DECLARATIONS.items():
            assert decl["renderer_id"] in RENDERER_ID_ALLOWLIST, (
                f"virtual kind {kind} has bad renderer_id {decl['renderer_id']!r}"
            )

    def test_virtual_kinds_function_emits_bindings(self):
        """The function form returns one binding per declaration."""
        virtuals = VirtualKindDeclarations()
        assert len(virtuals) == len(VIRTUAL_KIND_DECLARATIONS)
        for b in virtuals:
            assert b.source == "mvp_virtual"
            assert b.module_path == ""
            assert b.load_status == "virtual"


# ============================================================================
# Merger tests
# ============================================================================


class TestBindingMerger:
    def test_native_wins_on_collision(self):
        """If both sources declare the same kind, the apeiron-native wins."""
        native = [
            RendererBinding(
                kind="conflict", module_path="x.py", module_name="x",
                version="1.0", renderer_id="raster",
                source="apeiron_native",
            )
        ]
        virtual = [
            RendererBinding(
                kind="conflict", module_path="", module_name="",
                version="1.0", renderer_id="dom",
                source="mvp_virtual",
            )
        ]
        registry = BindingMerger(native, virtual)
        assert registry["conflict"].source == "apeiron_native"
        assert registry["conflict"].renderer_id == "raster"

    def test_both_sides_present_when_no_collision(self):
        """Distinct kinds from both sides should appear in the merged registry."""
        native = [
            RendererBinding(
                kind="alpha", module_path="a.py", module_name="a",
                version="1.0", renderer_id="raster",
                source="apeiron_native",
            )
        ]
        virtual = [
            RendererBinding(
                kind="beta", module_path="", module_name="",
                version="1.0", renderer_id="dom",
                source="mvp_virtual",
            )
        ]
        registry = BindingMerger(native, virtual)
        assert "alpha" in registry
        assert "beta" in registry


# ============================================================================
# Validator tests
# ============================================================================


class TestRegistryValidator:
    def test_missing_compose_reference_surfaces_error(self):
        """A virtual binding pointing at a non-existent kind must surface as an error."""
        registry = {
            "phantom_compose": RendererBinding(
                kind="phantom_compose", module_path="", module_name="",
                version="1.0", renderer_id="dom",
                composes=("nonexistent_kind",),
                source="mvp_virtual",
            )
        }
        valid, errors = RegistryValidator(registry)
        assert "phantom_compose" not in valid
        assert len(errors) == 1
        assert errors[0].error_type == "missing_compose"
        assert errors[0].kind == "phantom_compose"

    def test_bad_renderer_id_surfaces_error(self):
        """A renderer_id outside the allowlist is rejected."""
        registry = {
            "bad_renderer": RendererBinding(
                kind="bad_renderer", module_path="", module_name="",
                version="1.0", renderer_id="frobnicate",
                source="mvp_virtual",
            )
        }
        valid, errors = RegistryValidator(registry)
        assert "bad_renderer" not in valid
        assert errors[0].error_type == "bad_renderer_id"

    def test_valid_compose_references_pass(self):
        """A virtual kind composing an existing native passes validation."""
        registry = {
            "native_button": RendererBinding(
                kind="native_button", module_path="b.py", module_name="b",
                version="1.0", renderer_id="raster",
                source="apeiron_native",
            ),
            "virtual_widget": RendererBinding(
                kind="virtual_widget", module_path="", module_name="",
                version="1.0", renderer_id="dom",
                composes=("native_button",),
                source="mvp_virtual",
            ),
        }
        valid, errors = RegistryValidator(registry)
        assert "virtual_widget" in valid
        assert not errors


# ============================================================================
# Full registry build (end-to-end)
# ============================================================================


class TestRegistryBuild:
    def test_full_build_produces_no_errors(self):
        """The shipped registry must validate cleanly — every MVP kind's
        composes-refs resolve. If this fails, a kind declared in
        VIRTUAL_KIND_DECLARATIONS names an Apeiron module that doesn't
        actually exist (or has been renamed)."""
        reset_registry()
        reg = RendererRegistry.build()
        if reg.errors:
            details = "\n  ".join(
                f"[{e.error_type}] {e.kind}: {e.detail}" for e in reg.errors
            )
            pytest.fail(f"registry has {len(reg.errors)} validation errors:\n  {details}")

    def test_singleton_lazy_init(self):
        """get_registry() builds on first call; subsequent calls return the same instance."""
        reset_registry()
        r1 = get_registry()
        r2 = get_registry()
        assert r1 is r2

    def test_resolves_window_kind(self):
        """The window kind — the bottleneck per Sophia's review — must resolve."""
        reset_registry()
        reg = get_registry()
        b = reg.resolve("window")
        assert b is not None
        assert b.kind == "window"
        assert b.renderer_id == "dom"
        assert "panel_positioner" in b.composes

    def test_resolves_apeiron_primitives(self):
        """The canonical Apeiron primitives the dependency spreadsheet leans on must resolve."""
        reset_registry()
        reg = get_registry()
        for primitive in ("cube", "sphere", "computer", "panel_positioner", "list_renderer"):
            b = reg.resolve(primitive)
            assert b is not None, f"primitive {primitive} not in registry"
            assert b.source == "apeiron_native"

    def test_resolves_mvp_virtual_kinds(self):
        """Every MVP-declared virtual kind must resolve in the live registry."""
        reset_registry()
        reg = get_registry()
        for kind in VIRTUAL_KIND_DECLARATIONS:
            b = reg.resolve(kind)
            assert b is not None, f"virtual kind {kind} not in live registry"
            assert b.source == "mvp_virtual"

    def test_unknown_kind_returns_none(self):
        """Resolving a kind not in the registry returns None — not a crash."""
        reset_registry()
        reg = get_registry()
        assert reg.resolve("never-existed-kind") is None
        assert not reg.is_registered("never-existed-kind")


# ============================================================================
# Lookup interface tests
# ============================================================================


class TestRendererLookup:
    def test_list_kinds_sorted(self):
        reset_registry()
        reg = get_registry()
        kinds = reg.list_kinds()
        assert kinds == sorted(kinds)
        assert "window" in kinds
        assert "cube" in kinds

    def test_filter_by_renderer_id_dom(self):
        """The DOM-targeted kinds are the substrate-side ones the website renders."""
        reset_registry()
        reg = get_registry()
        dom_kinds = reg.filter_by_renderer_id("dom")
        # Every MVP-virtual DOM kind should appear here
        for kind, decl in VIRTUAL_KIND_DECLARATIONS.items():
            if decl["renderer_id"] == "dom":
                assert kind in dom_kinds, f"{kind} (renderer_id=dom) not in dom_kinds"

    def test_filter_by_renderer_id_canvas(self):
        """Canvas-targeted kinds (3d-canvas, painterly-output, camera)."""
        reset_registry()
        reg = get_registry()
        canvas_kinds = reg.filter_by_renderer_id("canvas")
        assert "3d-canvas" in canvas_kinds
        assert "painterly-output" in canvas_kinds
        assert "camera" in canvas_kinds

    def test_filter_by_composes(self):
        """Reverse lookup — which virtual kinds reuse a given native primitive."""
        reset_registry()
        reg = get_registry()
        # panel_positioner is reused by window, panel, calendar, paste-target,
        # right-click-menu, workspace — the dependency-spreadsheet attests
        positioner_users = reg.filter_by_composes("panel_positioner")
        assert "window" in positioner_users
        assert "panel" in positioner_users
        assert "calendar" in positioner_users
        assert "paste-target" in positioner_users

    def test_as_dict_serialization(self):
        """The registry must serialize for JSON / inbox-post."""
        reset_registry()
        reg = get_registry()
        d = reg.as_dict()
        assert "window" in d
        assert d["window"]["renderer_id"] == "dom"
        assert "panel_positioner" in d["window"]["composes"]


# ============================================================================
# Hot-reload semantics
# ============================================================================


class TestHotReload:
    def test_rebuild_returns_count_and_changes(self):
        """A rebuild must return (kinds_count, changed_kinds)."""
        reset_registry()
        reg = RendererRegistry.build()
        original_count = reg.kinds_count
        count, changed = reg.rebuild()
        assert count == original_count  # no actual changes on disk
        assert changed == []  # no diff vs previous snapshot

    def test_rebuild_after_artificial_kind_addition(self):
        """If we artificially add a kind, rebuild must detect the removal."""
        reset_registry()
        reg = RendererRegistry.build()
        fake = RendererBinding(
            kind="phantom_added", module_path="", module_name="",
            version="1.0", renderer_id="dom",
            source="mvp_virtual",
        )
        # Inject a phantom kind into the registry snapshot
        reg._registry["phantom_added"] = fake
        # Rebuild — the phantom should be gone (not in disk source)
        count, changed = reg.rebuild()
        assert "phantom_added" not in reg._registry
        assert "phantom_added" in changed

    def test_rebuild_updates_timestamp(self):
        """Rebuild must bump the last_rebuild_at timestamp."""
        reset_registry()
        reg = RendererRegistry.build()
        t0 = reg.last_rebuild_at
        # Ensure measurable time passes
        import time as _t
        _t.sleep(0.001)
        reg.rebuild()
        assert reg.last_rebuild_at > t0
