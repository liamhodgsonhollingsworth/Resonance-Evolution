"""scroll_window — Tool T1 from brief 02 per-module plan.

Per brief 02 commit 2 (per-module plan testing tools section).

Usage:
    python -m tools.workflow_streamlit.test_harnesses.scroll_window \
        --positions 100 \
        [--anchor <node_id_or_index>] \
        [--window <N,B_above,B_below>] \
        [--verbose]

Drives the continuous-scroll renderer programmatically. Generates a
synthetic workflow_view + position list, calls `render(...)`, and
asserts the resulting HTML matches the bands computed via
`select_window()` directly. Exits 0 on match, 1 on diff.

Composes against `select_window()` (the pure-function band logic) +
the renderer impl. The harness exists so the LLM-driver scenarios + the
plan-testing flow can exercise the renderer without spinning up
Streamlit. Brief 06 (text-API + terminal) will wrap this harness as an
MCP-callable so the LLM can invoke it via `execute_process_node`.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


HERE = Path(__file__).resolve()
APEIRON_ROOT = HERE.parent.parent.parent.parent
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.renderers.sliding_window import (  # noqa: E402
    parse_window_param,
    select_window,
)
from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import (  # noqa: E402
    render,
)


_DATA_NODE_ID_RE = re.compile(r'data-node-id="([^"]+)"')


def _mk_position(i: int) -> Dict[str, Any]:
    return {
        "node_id": f"sha256:{i:064x}",
        "appended_at": f"2026-05-22T00:00:{i:02d}Z",
        "appended_by": "scroll_window_harness",
        "provenance": {"source": "harness"},
    }


def _mk_workflow_view(n: int) -> Dict[str, Any]:
    return {
        "id": "sha256:harness_wv",
        "name": "workflow_view_main",
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": {
            "positions": [_mk_position(i) for i in range(n)],
            "default_paste_location": "end",
            "metadata": {
                "window": "50,20,20",
                "mode": "append-only",
                "surface": "workflow_continuous_scroll",
            },
        },
    }


def _resolve_anchor(
    anchor_arg: Optional[str], positions: List[Dict[str, Any]]
) -> Optional[Dict[str, Any]]:
    """The --anchor flag accepts either a full node_id or a positional index."""
    if anchor_arg is None:
        return None
    # Try as integer index first.
    try:
        idx = int(anchor_arg)
        if 0 <= idx < len(positions):
            return {"anchor": positions[idx]["node_id"]}
        raise ValueError(f"--anchor index {idx} out of range [0, {len(positions)})")
    except ValueError:
        pass
    # Fall back to literal node_id.
    return {"anchor": anchor_arg}


def _extract_rendered_node_ids(html: str) -> List[str]:
    return _DATA_NODE_ID_RE.findall(html)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument(
        "--positions",
        type=int,
        default=100,
        help="Number of synthetic workflow positions to generate (default 100).",
    )
    parser.add_argument(
        "--anchor",
        default=None,
        help=(
            "Optional anchor: either a positional index (0-based int) or a "
            "literal sha256:... node-id. When absent, the harness uses the "
            "scroll-to-bottom default."
        ),
    )
    parser.add_argument(
        "--window",
        default=None,
        help="Optional window override (CSV `N,B_above,B_below`). Default `50,20,20`.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print the rendered band and the select_window expectation as JSON.",
    )
    args = parser.parse_args()

    if args.positions < 0:
        print("scroll_window: --positions must be non-negative.", file=sys.stderr)
        return 2

    workflow_view = _mk_workflow_view(args.positions)
    positions = workflow_view["body"]["positions"]
    anchor_or_scroll = _resolve_anchor(args.anchor, positions)

    context: Dict[str, Any] = {}
    if args.window:
        context["window"] = args.window
    if anchor_or_scroll and "anchor" in anchor_or_scroll:
        context["anchor"] = anchor_or_scroll["anchor"]

    html = render({"content_nodes": [workflow_view], "context": context})

    # Expected bands from the pure function.
    window_triple = parse_window_param(args.window)
    expected_bands = select_window(
        positions=positions,
        anchor_or_scroll_position=anchor_or_scroll,
        window_param=window_triple,
    )

    rendered_ids = _extract_rendered_node_ids(html)
    expected_rendered = (
        expected_bands["buffer_above"]
        + expected_bands["visible"]
        + expected_bands["buffer_below"]
    )

    matches = rendered_ids == expected_rendered

    if args.verbose:
        print(
            json.dumps(
                {
                    "positions_total": len(positions),
                    "window": args.window or "50,20,20 (default)",
                    "anchor": args.anchor or "(scroll-to-bottom)",
                    "rendered_count": len(rendered_ids),
                    "expected_count": len(expected_rendered),
                    "matches": matches,
                },
                indent=2,
            )
        )

    if not matches:
        print(
            f"scroll_window: MISMATCH — rendered {len(rendered_ids)} ids, "
            f"expected {len(expected_rendered)}.",
            file=sys.stderr,
        )
        if args.verbose:
            print(
                json.dumps(
                    {
                        "rendered_ids": rendered_ids[:10],
                        "expected_ids": expected_rendered[:10],
                    },
                    indent=2,
                ),
                file=sys.stderr,
            )
        return 1

    print(
        f"scroll_window: OK — {len(rendered_ids)} ids rendered "
        f"({len(expected_bands['visible'])} visible + "
        f"{len(expected_bands['buffer_above'])} buffer_above + "
        f"{len(expected_bands['buffer_below'])} buffer_below; "
        f"{len(expected_bands['evicted'])} evicted)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
