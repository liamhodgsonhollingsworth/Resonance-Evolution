"""streamlit_panel_to_renderer_node — port-node implementation.

Per brief 02 commit 6 (Decision B5, SPEC-089) — the second of three
Streamlit-to-domain port-nodes.

Contract:
    translate({"panel_module": str, "panel_path": str?}) -> {
        "name": str,                # renderer-node name (from panel manifest)
        "kind": "renderer",
        "body-format": "renderer-spec",
        "body": {                   # SPEC-082 renderer-spec body
            "name": str,
            "description": str,
            "input": {"schema": ...},
            "output": {"schema": {"type": "string", "format": "html"}},
            "implementation": {
                "kind": "streamlit-wrapper",
                "path": str,
                "panel_module": str,
                "callable": "render_text",  # the text-API surface
            },
        },
    }

The port reads a Streamlit `panels/<name>.py` file (importing it as a
module via importlib), inspects its ``manifest()`` callable to extract
name + description + mount_point, and synthesizes a substrate-shaped
renderer-spec body that the literal-domain renderer can consume via
the new `streamlit-wrapper` impl-kind landed in this same commit.

Pure (modulo the dynamic import). Idempotent: the same panel module
produces the same renderer-spec body bit-for-bit.

Per Decision B5 tradeoff: when Streamlit isn't importable, the impl-
kind degrades gracefully (returns a placeholder); semantic equivalence
is preserved (the renderer-node's identity + manifest survive).
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any, Dict, Optional


_DEFAULT_PANELS_DIR = Path(__file__).resolve().parent.parent / "panels"


def _resolve_panel_path(panel_module: str, panel_path: Optional[str]) -> Path:
    """Locate the panel file on disk.

    Resolution order:
      1. If `panel_path` is given, use it verbatim.
      2. If `panel_module` looks like a bare module name (no slashes,
         no .py), assume it's at ``panels/<panel_module>.py``.
      3. Otherwise treat `panel_module` as a relative path.
    """
    if panel_path:
        return Path(panel_path)
    if "/" not in panel_module and "\\" not in panel_module and not panel_module.endswith(".py"):
        return _DEFAULT_PANELS_DIR / f"{panel_module}.py"
    return Path(panel_module)


def _try_load_manifest(panel_module_path: Path) -> Dict[str, Any]:
    """Best-effort load + manifest extraction.

    Returns a dict carrying ``name``, ``description``, ``mount_point``,
    ``order`` (with sensible fallbacks). Never raises — failures
    produce a partial manifest with ``error`` set.
    """
    fallback = {
        "name": panel_module_path.stem,
        "description": f"Streamlit panel at {panel_module_path}",
        "mount_point": "main",
        "order": 100,
    }
    if not panel_module_path.exists():
        return {**fallback, "error": f"panel module not found at {panel_module_path}"}

    # Stub Streamlit if not installed so the import succeeds.
    import sys as _sys
    streamlit_present = True
    try:
        import streamlit  # type: ignore  # noqa: F401
    except ImportError:
        streamlit_present = False
        _sys.modules.setdefault("streamlit", _streamlit_stub_module())

    try:
        spec = importlib.util.spec_from_file_location(
            f"_port_streamlit_panel_{panel_module_path.stem}",
            panel_module_path,
        )
        if spec is None or spec.loader is None:
            return {**fallback, "error": f"could not load module spec for {panel_module_path}"}
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as exc:
        return {**fallback, "error": f"panel import failed: {type(exc).__name__}: {exc}"}

    manifest_fn = getattr(module, "manifest", None)
    if not callable(manifest_fn):
        return {**fallback, "warning": "panel has no manifest() callable"}

    try:
        m = manifest_fn()
    except Exception as exc:
        return {**fallback, "error": f"manifest() raised: {type(exc).__name__}: {exc}"}

    out = dict(fallback)
    for attr in ("name", "description", "mount_point", "order"):
        if hasattr(m, attr):
            v = getattr(m, attr)
            if v is not None:
                out[attr] = v
    out["streamlit_present"] = streamlit_present
    return out


def _streamlit_stub_module():
    """Light-weight stub for absent Streamlit (importable as `streamlit`)."""
    class _Stub:
        __name__ = "streamlit"
        def __getattr__(self, _name):
            def _noop(*a, **kw):
                return _Stub()
            return _noop
        def __call__(self, *a, **kw):
            return self
        def __getitem__(self, _k):
            return None
    return _Stub()


def translate(payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Wrap a Streamlit panel as a substrate renderer-node dict.

    Input keys:
      - ``panel_module``: str (required) — the panel's module name
        (e.g. "chat_panel") OR a relative path.
      - ``panel_path``: str (optional) — explicit absolute path to
        override the default ``panels/<panel_module>.py`` resolution.
      - ``path_prefix``: str (optional) — project-relative prefix to
        embed in the resulting renderer-spec's `implementation.path`.
        Default: ``Apeiron/tools/workflow_streamlit/panels/<name>.py``.

    Output: a renderer-node dict (NOT published — caller's
    responsibility) carrying:
      - name (matches panel manifest name)
      - kind: "renderer"
      - body-format: "renderer-spec"
      - body: full SPEC-082 renderer-spec body with
        implementation.kind = "streamlit-wrapper"

    Pure modulo the dynamic import; idempotent.
    """
    if payload is None:
        payload = {}
    if not isinstance(payload, dict):
        raise TypeError(
            f"streamlit_panel_to_renderer_node.translate: payload must be a dict; "
            f"got {type(payload).__name__}"
        )
    panel_module = payload.get("panel_module")
    if not isinstance(panel_module, str) or not panel_module.strip():
        raise ValueError(
            "streamlit_panel_to_renderer_node.translate: payload['panel_module'] "
            "must be a non-empty string"
        )
    panel_path = payload.get("panel_path")
    path_prefix = payload.get(
        "path_prefix",
        "Apeiron/tools/workflow_streamlit/panels/",
    )

    panel_module_path = _resolve_panel_path(panel_module, panel_path)
    manifest_data = _try_load_manifest(panel_module_path)

    name = str(manifest_data.get("name") or panel_module_path.stem)
    description = str(
        manifest_data.get("description")
        or f"Streamlit panel {name} wrapped as a renderer-node via SPEC-089 port."
    )

    # Implementation path: project-relative form so the substrate's
    # path-allowlist (_EXECUTE_ALLOWED_PATH_PREFIXES) accepts it.
    impl_path = f"{path_prefix.rstrip('/')}/{panel_module_path.name}"

    renderer_spec_body: Dict[str, Any] = {
        "name": name,
        "description": description,
        "input": {
            "schema": {
                "type": "object",
                "properties": {
                    "ctx": {
                        "type": "object",
                        "description": (
                            "PanelContext-shaped dict carrying engine, "
                            "session_manager, inbox, config etc. May be empty "
                            "when called from the literal-domain wrapper — "
                            "the streamlit-wrapper impl-kind degrades to "
                            "describe()/manifest() output."
                        ),
                    },
                },
            },
        },
        "output": {
            "schema": {
                "type": "string",
                "format": "html",
            },
        },
        "implementation": {
            "kind": "streamlit-wrapper",
            "path": impl_path,
            "panel_module": name,
            "callable": "render_text",
        },
    }

    return {
        "name": name,
        "kind": "renderer",
        "body-format": "renderer-spec",
        "body": renderer_spec_body,
        "_origin": {
            "port": "streamlit_panel_to_renderer_node",
            "source_panel_module": panel_module,
            "source_panel_path": str(panel_module_path),
            "manifest_status": "ok" if "error" not in manifest_data else "fallback",
            "streamlit_present": manifest_data.get("streamlit_present", False),
        },
    }


__all__ = ["translate"]
