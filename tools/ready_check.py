"""
Apeiron readiness check — SPEC-064.

Headless verification that the workflow surface is end-to-end functional
**before** instructing the maintainer to open the program. Composes a
sequence of probes against the production `scenes/workflow_view.json`:

1. Engine discover() loads every node-type cleanly (no errors).
2. Scene load + precompute produces all expected source caches.
3. Every advertised text-API surface dispatches without error.
4. Reversibility cycles (expand/collapse, mode-toggle) preserve state.
5. Trust-set primitives round-trip cleanly.
6. The desktop shortcut exists and points at the launch .bat.

Exit code 0 on full pass; non-zero on any failure with the offending
probe named. Designed to be the gate the session passes before any
"open the program" closing-block instruction (SPEC-061's
alert-only-when-ready discipline).

Usage::

    python -m tools.ready_check

Optional ``--verbose`` for per-probe output.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Callable, List, Tuple

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))


def _check_engine_discover(verbose: bool) -> Tuple[bool, str]:
    from engine import Engine
    from tools.workflow.trust import render_trust_set

    e = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    e.discover()
    required_types = {
        "WorkflowView", "ListRenderer", "FileSource",
        "QuarantineSource", "TrustedSendersSource",
    }
    missing = required_types - set(e.types)
    if missing:
        return False, f"node-types missing: {sorted(missing)}"
    if e.errors:
        return False, f"engine errors at discover: {e.errors[:3]}"
    return True, f"all {len(required_types)} required node-types load cleanly"


def _check_scene_precompute(verbose: bool) -> Tuple[bool, str]:
    from engine import Engine
    from tools.workflow.trust import render_trust_set

    e = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    t0 = time.perf_counter()
    e.precompute()
    elapsed = time.perf_counter() - t0
    if e.errors:
        return False, f"precompute produced errors: {e.errors[:3]}"
    if elapsed > 10.0:
        return False, f"precompute took {elapsed:.1f}s (over 10s budget)"
    panels = ("task_panel", "idea_panel", "wish_panel",
              "quarantine_panel", "trusted_senders_panel")
    for p in panels:
        if p not in e.nodes:
            return False, f"panel node missing: {p}"
        if e.nodes[p].dead:
            return False, f"panel {p} dead after precompute"
    return True, f"scene precompute in {elapsed*1000:.0f}ms, all 5 panels live"


def _check_text_api_parity(verbose: bool) -> Tuple[bool, str]:
    from engine import Engine
    from tools.text_test import dispatch_command
    from tools.workflow.trust import render_trust_set

    e = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.precompute()
    items = e.cache.get("wishes_source", {}).get("items") or []
    if not items:
        return False, "wishes_source has no items — cannot exercise expand"
    target = items[0]["id"]
    commands = [
        f"expand wish_panel {target}",
        "collapse wish_panel",
        "set-mode workflow_view full_render",
        "set-mode workflow_view panels",
        "describe workflow_view",
        "list-commands",
    ]
    for cmd in commands:
        msg, _ = dispatch_command(e, cmd)
        if msg.startswith("ERR") or msg.startswith("unknown"):
            return False, f"text-API command failed: {cmd!r} -> {msg}"
    return True, f"all {len(commands)} text-API commands dispatched cleanly"


def _check_reversibility_cycles(verbose: bool) -> Tuple[bool, str]:
    from engine import Engine
    from engine.actions import get_view_state
    from tools.text_test import dispatch_command
    from tools.workflow.trust import render_trust_set

    e = Engine(root_dir=ROOT, trust_set=render_trust_set(ROOT))
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.precompute()
    target = e.cache["wishes_source"]["items"][0]["id"]

    # expand/collapse cycle
    initial_view_state = dict(get_view_state(e, "wish_panel"))
    for _ in range(20):
        dispatch_command(e, f"expand wish_panel {target}")
        dispatch_command(e, "collapse wish_panel")
    final_view_state = dict(get_view_state(e, "wish_panel"))
    if final_view_state.get("expanded_item") != initial_view_state.get("expanded_item"):
        return False, (
            f"expand/collapse drifted: initial={initial_view_state} "
            f"final={final_view_state}"
        )

    # workflow mode toggle cycle
    initial_mode = e.nodes["workflow_view"].state["mode"]
    for _ in range(20):
        dispatch_command(e, "set-mode workflow_view full_render")
        dispatch_command(e, "set-mode workflow_view panels")
    final_mode = e.nodes["workflow_view"].state["mode"]
    if final_mode != initial_mode:
        return False, f"mode toggle drifted: initial={initial_mode} final={final_mode}"

    return True, "expand/collapse + mode-toggle reversibility holds over 20 cycles each"


def _check_trust_set_round_trip(verbose: bool) -> Tuple[bool, str]:
    import tempfile
    from tools.workflow.trust import sender_trust_set

    with tempfile.TemporaryDirectory() as td:
        ts = sender_trust_set(Path(td), user="LHH")
        initial = frozenset(ts.list_trusted())
        for _ in range(30):
            ts.add("round-trip")
            ts.remove("round-trip")
        final = frozenset(ts.list_trusted())
        if final != initial:
            return False, f"trust-set add/remove drifted: initial={initial} final={final}"
    return True, "trust-set add/remove round-trips over 30 cycles"


def _check_launcher_scene_arg(verbose: bool) -> Tuple[bool, str]:
    """Simulate the launcher's argv resolution: `--scene workflow_view`
    (the .bat passes this) must resolve to an existing scene file.
    Catches the bug where the shell looks for `scenes/workflow_view`
    without the .json suffix and `--launch-realtime` then warns and
    skips the window."""
    # Mirror the shell's resolution logic.
    candidate = ROOT / "scenes" / "workflow_view"
    if candidate.exists():
        return True, "launcher arg resolves to a real scene"
    with_suffix = candidate.with_suffix(".json")
    if with_suffix.exists():
        return True, f"launcher arg resolves via .json fallback to {with_suffix.name}"
    return False, (
        f"launcher arg `--scene workflow_view` would fail: "
        f"{candidate} and {with_suffix} both missing"
    )


def _check_claude_auth_status(verbose: bool) -> Tuple[bool, str]:
    """Spawned sessions need OAuth login (post-API-key-strip). Probe
    `claude auth status` and assert loggedIn=true. This catches the
    case where the maintainer was authenticated only via
    ANTHROPIC_API_KEY and the strip leaves them with no credentials."""
    import json
    import shutil
    import subprocess

    claude_bin = shutil.which("claude") or shutil.which("claude.cmd")
    if not claude_bin:
        return False, "claude CLI not on PATH; required for spawned sessions"
    try:
        # Strip API key from probe env so the status reflects post-strip state.
        env = os.environ.copy()
        for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
                    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX"):
            env.pop(key, None)
        result = subprocess.run(
            [claude_bin, "auth", "status"],
            capture_output=True, text=True, timeout=10, env=env,
        )
    except subprocess.TimeoutExpired:
        return False, "claude auth status timed out (>10s)"
    # `claude auth status` exits 1 when not logged in but still emits JSON
    # to stdout. Parse stdout regardless of exit code; only treat
    # non-JSON output as a hard failure.
    if not result.stdout.strip():
        return False, (
            f"claude auth status produced no output (exit={result.returncode}); "
            f"stderr: {result.stderr.strip()[:200]}"
        )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return False, f"claude auth status returned non-JSON: {result.stdout.strip()[:200]}"
    if not data.get("loggedIn"):
        return False, (
            f"not logged in (authMethod={data.get('authMethod')!r}) - "
            f"run `claude auth login` to authenticate spawned sessions to "
            f"the Claude Code plan"
        )
    return True, f"logged in via authMethod={data.get('authMethod')!r}"


def _check_desktop_shortcut(verbose: bool) -> Tuple[bool, str]:
    if os.name != "nt":
        return True, "not Windows; desktop shortcut check skipped"
    desktop = Path(os.environ.get("USERPROFILE", "")) / "Desktop"
    if not desktop.exists():
        return True, f"desktop dir not found at {desktop}; skipping shortcut check"
    lnk = desktop / "Apeiron.lnk"
    if not lnk.exists():
        return False, (
            f"desktop shortcut missing at {lnk}; "
            f"run scripts/create_desktop_shortcut.ps1"
        )
    return True, f"desktop shortcut present at {lnk}"


def _check_billing_env_strip(verbose: bool) -> Tuple[bool, str]:
    """SessionManager must strip billing-mode env vars before spawning
    claude — otherwise spawned sessions charge per call instead of using
    the Claude Code plan. Read the source as the cheapest probe."""
    src = (ROOT / "tools" / "workflow" / "session_manager.py").read_text(encoding="utf-8")
    required_strips = (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
    )
    for key in required_strips:
        if f"\"{key}\"" not in src and f"'{key}'" not in src:
            return False, f"session_manager.py does not pop {key} from subprocess env"
    if "env.pop(" not in src and "env = " not in src:
        return False, "session_manager.py: no env-strip code visible"
    return True, "session_manager strips all 4 billing-mode env vars before spawn"


def _check_gui_test_driver_smoke(verbose: bool) -> Tuple[bool, str]:
    """SPEC-081: the text-API GUI test driver lets the session exercise
    every GUI verb end-to-end without launching a Tk window. This probe
    runs the canonical smoke test and asserts the expected final state
    (scale back to 1.0, Quarantine archived, ctrl_held cleared).

    Headless — runs anywhere. If this probe ever fails, a GUI feature
    silently broke the text-API surface that future sessions depend on.
    """
    try:
        from tools.gui_test_driver import GuiDriver, _smoke
    except Exception as exc:
        return False, f"gui_test_driver import failed: {exc}"
    try:
        drv = GuiDriver()
        report = _smoke(drv)
    except Exception as exc:
        return False, f"gui smoke raised: {exc}"
    if not report:
        return False, "gui smoke produced no steps"
    final = drv.read_state()
    if final.get("ctrl_held") is not False:
        return False, f"gui smoke left ctrl_held={final.get('ctrl_held')!r}"
    if final.get("sidebar_scale") != 1.0:
        return False, f"gui smoke left scale={final.get('sidebar_scale')!r}"
    if "Quarantine" in drv.tab_order():
        return False, "gui smoke archive step did not remove Quarantine"
    return True, f"gui smoke executed {len(report)} verbs cleanly; final state nominal"


def _check_active_sessions(verbose: bool) -> Tuple[bool, str]:
    """SPEC-079: the active-sessions registry primitive must
    round-trip register / heartbeat / list / unregister in a tmp
    state dir without touching production state. Also asserts the
    Sessions view is registered in the default view registry.
    """
    import tempfile
    from pathlib import Path as _Path

    try:
        from tools.active_sessions import (
            heartbeat,
            list_active_sessions,
            register_session,
            unregister_session,
        )
        from tools.workflow_gui.view_registry import default_view_registry
    except Exception as exc:
        return False, f"active_sessions import failed: {exc}"

    with tempfile.TemporaryDirectory() as td:
        path = _Path(td)
        register_session("probe", "apeiron", "ready-check",
                         focus="ready-check probe", state_dir=path)
        sessions = list_active_sessions(state_dir=path)
        if not any(s.id == "probe" for s in sessions):
            return False, "register_session did not surface in list_active_sessions"
        if not heartbeat("probe", focus="probe heartbeat", state_dir=path):
            return False, "heartbeat returned False on freshly-registered session"
        if not unregister_session("probe", state_dir=path):
            return False, "unregister_session returned False on registered session"
        if list_active_sessions(state_dir=path):
            return False, "unregister did not remove the entry"

    # Sessions view must be registered in the default registry.
    reg = default_view_registry()
    spec = reg.get("Sessions")
    if spec is None:
        return False, "Sessions view missing from default_view_registry"
    if spec.kind != "dynamic":
        return False, f"Sessions view has kind={spec.kind!r}; expected 'dynamic'"
    if spec.items_provider is None:
        return False, "Sessions view has no items_provider"

    return True, (
        "active-sessions registry round-trips register/heartbeat/"
        "list/unregister cleanly; Sessions view registered in default registry"
    )


def _check_view_registry(verbose: bool) -> Tuple[bool, str]:
    """SPEC-067: the workflow GUI exposes a view registry whose
    ``set-view`` text command + gui_test_driver verbs let any caller
    enumerate, switch, archive, and restore views without launching Tk.

    Probe: load the default registry, assert every Arc K tab is
    present, exercise set/archive/restore + register a runtime view +
    set-view it via the text-API, then confirm legacy mirrors stay in
    sync. Headless — no Tk root required.
    """
    try:
        from tools.gui_test_driver import GuiDriver
        from tools.text_test import dispatch_command
        from tools.workflow_gui.view_registry import (
            ViewSpec,
            default_view_registry,
        )
    except Exception as exc:
        return False, f"view registry import failed: {exc}"

    reg = default_view_registry()
    required = {
        "Tasks", "Ideas", "Wishlist", "Inbox", "Chat",
        "Quarantine", "Trusted Senders", "3D", "Logs",
    }
    missing = required - set(reg.names())
    if missing:
        return False, f"default registry missing views: {sorted(missing)}"

    # Drive a fresh GuiDriver through every SPEC-067 verb.
    drv = GuiDriver()
    drv.build()
    if drv.set_view("Ideas") is not True:
        return False, "set_view('Ideas') did not activate"
    if drv.current_view() != "Ideas":
        return False, f"current_view() = {drv.current_view()!r} after set_view"

    # Archive + restore round-trip preserves the visible list.
    initial = list(drv.list_views())
    drv.hold_ctrl()
    drv.ctrl_click("Quarantine")
    if "Quarantine" not in drv.archived_views():
        return False, "archive did not register in archived_views"
    drv.restore_view("Quarantine")
    if drv.list_views() != initial:
        return False, (
            f"archive/restore drifted: initial={initial!r} after={drv.list_views()!r}"
        )

    # Runtime registration is one ViewSpec away.
    drv.register_view(
        ViewSpec(
            name="ReadyCheckView",
            kind="text",
            description="probe-internal view",
            text_body="ok",
        )
    )
    if "ReadyCheckView" not in drv.list_views():
        return False, "register_view did not surface in list_views"
    if drv.set_view("ReadyCheckView") is not True:
        return False, "set_view on runtime-registered view failed"

    # text-API set-view command resolves end-to-end.
    msg, _ = dispatch_command(drv.shell.engine, "set-view Tasks")
    if not msg.startswith("OK"):
        return False, f"text-API set-view did not return OK: {msg!r}"
    if drv.current_view() != "Tasks":
        return False, f"text-API set-view did not switch (current={drv.current_view()!r})"

    # list-views text-API surfaces every registered view.
    msg, _ = dispatch_command(drv.shell.engine, "list-views")
    if "Tasks" not in msg or "Logs" not in msg:
        return False, "list-views output missing built-in entries"

    return True, (
        f"view registry healthy: {len(drv.list_views())} visible, "
        f"set-view + archive/restore + register_view all functional"
    )


def _check_workflow_gui_module(verbose: bool) -> Tuple[bool, str]:
    """SPEC-065: the 2D Tk GUI shell module must import cleanly and
    expose its tab catalog + data providers. Headless probe — does not
    open a Tk window, so it runs anywhere the regular suite runs.

    What this catches: a refactor that breaks the data-provider
    signatures, a tab dropped from the catalog, or a circular import
    introduced by future cross-module coupling.
    """
    try:
        from tools.workflow_gui.gui_shell import (
            DEFAULT_TAB,
            GuiShell,
            TABS,
            items_from_engine_cache,
            items_from_inbox,
            items_from_sessions,
            main,
        )
    except Exception as exc:
        return False, f"workflow_gui import failed: {exc}"
    required_tabs = {
        "Tasks", "Ideas", "Wishlist", "Inbox", "Chat",
        "Quarantine", "Trusted Senders", "3D",
    }
    tab_names = {name for name, _, _ in TABS}
    missing = required_tabs - tab_names
    if missing:
        return False, f"workflow_gui TABS missing: {sorted(missing)}"
    if DEFAULT_TAB not in tab_names:
        return False, f"workflow_gui DEFAULT_TAB {DEFAULT_TAB!r} not in TABS"
    # Light callable check on the providers + main entry — confirms the
    # surface a caller depends on still exists.
    for fn in (items_from_engine_cache, items_from_inbox, items_from_sessions, main):
        if not callable(fn):
            return False, f"workflow_gui surface broken: {fn!r} not callable"
    return True, (
        f"workflow_gui import clean, {len(tab_names)} tabs registered, "
        f"default={DEFAULT_TAB!r}"
    )


def _check_transcript_reader(verbose: bool) -> Tuple[bool, str]:
    """SPEC-070: the transcript reader must locate and render at least
    one real on-disk session cleanly. Probes the parser end-to-end
    against the most-recently-modified session JSONL — a session that
    exists is the only precondition; the reader handles any size/shape."""
    from tools.transcript_reader import (
        list_all_sessions, parse_transcript, render_markdown,
    )

    sessions = list_all_sessions()
    if not sessions:
        # No transcripts on disk yet — not a failure, just nothing to probe.
        return True, "no session JSONLs on disk yet; reader is wired in"
    sessions.sort(key=lambda s: s["mtime"], reverse=True)
    target = Path(sessions[0]["path"])
    try:
        transcript = parse_transcript(target)
        rendered = render_markdown(transcript)
    except Exception as exc:  # pragma: no cover - defensive
        return False, f"transcript reader crashed on {target.name}: {exc}"
    if not rendered.startswith("# Session "):
        return False, "rendered transcript missing session header"
    return True, (
        f"reader parsed {target.name} -> {len(transcript.turns)} turns, "
        f"{len(rendered)} chars"
    )


CHECKS: List[Tuple[str, Callable[[bool], Tuple[bool, str]]]] = [
    ("engine_discover", _check_engine_discover),
    ("scene_precompute", _check_scene_precompute),
    ("text_api_parity", _check_text_api_parity),
    ("reversibility_cycles", _check_reversibility_cycles),
    ("trust_set_round_trip", _check_trust_set_round_trip),
    ("billing_env_strip", _check_billing_env_strip),
    ("launcher_scene_arg", _check_launcher_scene_arg),
    ("claude_auth_status", _check_claude_auth_status),
    ("desktop_shortcut", _check_desktop_shortcut),
    ("transcript_reader", _check_transcript_reader),
    ("workflow_gui_module", _check_workflow_gui_module),
    ("gui_test_driver_smoke", _check_gui_test_driver_smoke),
    ("view_registry", _check_view_registry),
    ("active_sessions", _check_active_sessions),
]


def run_all(verbose: bool = False) -> int:
    print(f"Apeiron readiness check — {len(CHECKS)} probes\n")
    failures: List[str] = []
    for name, fn in CHECKS:
        t0 = time.perf_counter()
        try:
            ok, msg = fn(verbose)
        except Exception as exc:
            ok = False
            msg = f"probe raised: {exc!r}"
        elapsed = time.perf_counter() - t0
        marker = "OK " if ok else "FAIL"
        print(f"  [{marker}] {name:24s} ({elapsed*1000:.0f}ms) -- {msg}")
        if not ok:
            failures.append(name)
    print()
    if failures:
        print(f"READY: NO -- {len(failures)} failed: {', '.join(failures)}")
        return 1
    print("READY: YES -- all probes passed; safe to instruct maintainer to open the program")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="tools.ready_check")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    return run_all(verbose=args.verbose)


if __name__ == "__main__":
    raise SystemExit(main())
