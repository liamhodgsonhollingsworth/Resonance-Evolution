"""paste_content_mapper — Tool T3 from brief 02 per-module plan.

Per brief 02 commit 4 (Decision B3, SPEC-087).

Usage:
    python -m tools.workflow_streamlit.test_harnesses.paste_content_mapper \\
        [--content-type <mime>] [--content-file <path>] [--content <inline>] \\
        [--source <hint>] [--verbose]

Drives the SPEC-087 dispatcher against either inline content or a
fixture file, prints the routed-to kind, and (in verbose mode) emits
the full SpawnSpec.params for inspection. Exit code 0 on a clean
dispatch; 1 on dispatcher-internal error.

Composes against:
  - `Alethea-cc/tools/paste_dispatch/dispatch.py::dispatch()` — the
    canonical decision point.
  - No engine surface: this harness exercises the LIBRARY contract
    so it can run in any environment Alethea-cc reaches (including
    pre-engine CI smoke).

Brief 06 wraps this harness as an MCP-callable so the LLM-driver
scenarios can exercise paste-dispatch via `execute_process_node`.
The harness mirrors `append_only_probe.py` (Tool T2) + `scroll_window.py`
(Tool T1) in CLI shape — same `--verbose` JSON-on-stdout convention,
same path-discovery convention for Alethea-cc.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, Optional

HERE = Path(__file__).resolve()
APEIRON_ROOT = HERE.parent.parent.parent.parent
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))


def _discover_paste_dispatch() -> Any:
    """Import the Alethea-cc paste_dispatch toolbox via an explicit file-
    system path lookup so we don't collide with Apeiron's own `tools`
    package on the import path."""
    import importlib.util
    candidate = APEIRON_ROOT.parent / "Alethea" / "Alethea-cc" / "tools" / "paste_dispatch"
    pkg_init = candidate / "__init__.py"
    if not pkg_init.exists():
        raise SystemExit(
            f"paste_content_mapper: paste_dispatch toolbox not found at {pkg_init}"
        )
    module_name = "alethea_cc_paste_dispatch"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(
        module_name,
        str(pkg_init),
        submodule_search_locations=[str(candidate)],
    )
    if spec is None or spec.loader is None:
        raise SystemExit(
            f"paste_content_mapper: spec could not be built for {pkg_init}"
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _resolve_content(args: argparse.Namespace) -> str:
    if args.content_file:
        path = Path(args.content_file)
        if not path.exists():
            raise SystemExit(f"paste_content_mapper: file not found: {path}")
        return path.read_text(encoding="utf-8", errors="replace")
    if args.content is not None:
        return args.content
    # Read from stdin.
    return sys.stdin.read()


def _format_summary(result: Any) -> str:
    parts = [
        f"route={result.route}",
        f"kind={result.kind}",
        f"detected_via={result.detected_via}",
    ]
    if result.mime_hint:
        parts.append(f"mime={result.mime_hint}")
    if result.source_hint:
        parts.append(f"source={result.source_hint}")
    return " ".join(parts)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--content-type", dest="mime", default=None)
    parser.add_argument("--content-file", dest="content_file", default=None)
    parser.add_argument("--content", dest="content", default=None)
    parser.add_argument("--source", dest="source", default=None)
    parser.add_argument(
        "--asset-dir",
        dest="asset_dir",
        default=None,
        help="directory for image-data-URI saves (default: dry-run, embed)",
    )
    parser.add_argument(
        "--asset-base-url",
        dest="asset_base_url",
        default="",
        help="URL prefix for saved image-asset paths (default: relative)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="emit full SpawnSpec on stdout"
    )
    args = parser.parse_args(argv)

    paste_dispatch = _discover_paste_dispatch()
    content = _resolve_content(args)

    asset_dir: Optional[Path] = None
    if args.asset_dir:
        asset_dir = Path(args.asset_dir)

    try:
        result = paste_dispatch.dispatch(
            content,
            mime_hint=args.mime,
            source_hint=args.source,
            asset_dir=asset_dir,
            asset_base_url=args.asset_base_url,
        )
    except Exception as exc:
        sys.stderr.write(f"paste_content_mapper: dispatch failed: {exc}\n")
        return 1

    summary = _format_summary(result)
    print(summary)
    if args.verbose:
        payload: Dict[str, Any] = {
            "route": result.route,
            "kind": result.kind,
            "detected_via": result.detected_via,
            "mime_hint": result.mime_hint,
            "source_hint": result.source_hint,
            "is_module_clipboard_route": result.is_module_clipboard_route(),
            "spawn_spec": None,
        }
        if result.spawn_spec is not None:
            payload["spawn_spec"] = {
                "kind": result.spawn_spec.kind,
                "params": result.spawn_spec.params,
                "side_effects": list(result.spawn_spec.side_effects),
            }
        print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
