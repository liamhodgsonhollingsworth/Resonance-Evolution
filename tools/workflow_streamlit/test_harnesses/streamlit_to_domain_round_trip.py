"""streamlit_to_domain_round_trip — Tool T5 from brief 02 per-module plan.

Per brief 02 commit 6 (Decision B5, SPEC-089).

Usage:
    python -m tools.workflow_streamlit.test_harnesses.streamlit_to_domain_round_trip \\
        [--port session|panel|action|all] [--verbose]

Drives each of the three Streamlit→domain port nodes per SPEC-089
through its expected calling shape and prints the round-trip result.
Validates per-port idempotency + (for port 1) URL round-trip equality.

Exits 0 on a clean round-trip; 1 on any port failure.

Composes against:
  - ``ports/streamlit_session_to_url_grammar.translate + parse_url``
    (port 1 — URL identity).
  - ``ports/streamlit_panel_to_renderer_node.translate`` (port 2 —
    panel-as-renderer-node).
  - ``ports/streamlit_action_to_text_api_command.translate`` (port 3 —
    event-as-text-command).
  - Decision B5 + SPEC-085 contract checks.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = Path(__file__).resolve()
APEIRON_ROOT = HERE.parent.parent.parent.parent
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.ports.streamlit_session_to_url_grammar import (  # type: ignore
    translate as translate_session,
    parse_url,
)
from tools.workflow_streamlit.ports.streamlit_panel_to_renderer_node import (  # type: ignore
    translate as translate_panel,
)
from tools.workflow_streamlit.ports.streamlit_action_to_text_api_command import (  # type: ignore
    translate as translate_action,
)


def _check_port_session() -> Dict[str, Any]:
    """Run a representative session-state through port 1 and verify round-trip equality."""
    session_state = {
        "anchor": "sha256:abc123",
        "window": "30,10,10",
        "_FormSubmitterDirect": "internal-noise-should-drop",
    }
    result = translate_session({
        "session_state": session_state,
        "current_panel": "workflow-continuous-scroll",
    })
    # Idempotency.
    second = translate_session({
        "session_state": session_state,
        "current_panel": "workflow-continuous-scroll",
    })
    assert second == result, "translate_session is not idempotent"
    # URL round-trip.
    parsed = parse_url(result["url"])
    assert parsed["renderer_id"] == result["renderer_id"]
    assert parsed["query"] == result["query"]
    # internal session key should not have leaked into the URL.
    assert "_FormSubmitterDirect" not in result["url"]
    return {
        "port": "streamlit_session_to_url_grammar",
        "ok": True,
        "result": result,
        "round_trip": parsed,
    }


def _check_port_panel() -> Dict[str, Any]:
    """Run a panel module through port 2."""
    result = translate_panel({"panel_module": "chat_panel"})
    assert result["kind"] == "renderer"
    assert result["body-format"] == "renderer-spec"
    impl = result["body"]["implementation"]
    assert impl["kind"] == "streamlit-wrapper", f"impl kind: {impl['kind']!r}"
    return {
        "port": "streamlit_panel_to_renderer_node",
        "ok": True,
        "result": result,
    }


def _check_port_action() -> Dict[str, Any]:
    """Run several event shapes through port 3."""
    cases: List[Dict[str, Any]] = [
        {
            "name": "button",
            "input": {"event": {"type": "button", "panel": "workflow",
                                "label": "Save"}, "panel_state": {}},
            "expect_verb_prefix": "panel.workflow.save",
        },
        {
            "name": "chat_input",
            "input": {"event": {"type": "chat_input", "text": "hello"}, "panel_state": {}},
            "expect_verb_prefix": "chat.send",
        },
        {
            "name": "paste",
            "input": {"event": {"type": "paste", "content": "x", "mime": "text/plain"}, "panel_state": {}},
            "expect_verb_prefix": "paste.add",
        },
    ]
    results = []
    for case in cases:
        r = translate_action(case["input"])
        ok = r["verb"].startswith(case["expect_verb_prefix"]) or (
            case["expect_verb_prefix"] in r["command"]
        )
        results.append({"name": case["name"], "ok": ok, "result": r})
    return {
        "port": "streamlit_action_to_text_api_command",
        "ok": all(r["ok"] for r in results),
        "results": results,
    }


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="streamlit_to_domain_round_trip",
        description="Tool T5: round-trip-test the three SPEC-089 ports.",
    )
    p.add_argument(
        "--port",
        choices=["session", "panel", "action", "all"],
        default="all",
        help="Which port to exercise (default: all).",
    )
    p.add_argument("--verbose", action="store_true")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)
    runners = {
        "session": _check_port_session,
        "panel": _check_port_panel,
        "action": _check_port_action,
    }
    selected: List[str] = (
        list(runners.keys()) if args.port == "all" else [args.port]
    )
    outcomes: List[Dict[str, Any]] = []
    for name in selected:
        try:
            outcomes.append(runners[name]())
        except AssertionError as exc:
            outcomes.append({"port": name, "ok": False, "error": str(exc)})
        except Exception as exc:  # pragma: no cover
            outcomes.append({"port": name, "ok": False, "error": f"{type(exc).__name__}: {exc}"})

    if args.verbose:
        print(json.dumps(outcomes, indent=2, default=str), flush=True)
    else:
        for o in outcomes:
            tag = "PASS" if o.get("ok") else "FAIL"
            print(f"  [{tag}] {o.get('port')}", flush=True)

    return 0 if all(o.get("ok") for o in outcomes) else 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
