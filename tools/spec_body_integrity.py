"""SPEC body integrity check — fifth input stream for the workflow-
management auto-review routine (deferred-concerns #28 / A6-4).

Closes deferred-concerns #28: the wave-I-2-relief gutting of multiple
SPEC bodies was NOT surfaced by the auto-review — the routine's four
input streams (recent inbox messages, recent workflow_view appends,
active sessions, open SPECs in pending status) don't notice when a
SPEC body shrinks under destructive splitter runs. PR #175 prevents
the gutting at the splitter level, but the auto-review still
wouldn't catch manual destructive edits.

This module ships the fifth input stream as a Python helper the
auto-review session can call. It:

  1. Iterates per-spec node files in the sibling Alethea-cc
     repo (``Alethea-cc/nodes/spec_*.md``).
  2. Computes the current body-line count for each (body =
     everything after the closing ``---`` of the YAML frontmatter).
  3. Compares against a baseline file at
     ``<apeiron-root>/state/auto_review/spec_body_baselines.json``
     (creating it on first run with the current counts).
  4. Returns a list of alerts for any SPEC whose body shrunk by more
     than the configured threshold (default 50%).
  5. Updates the baseline file after each run so the next run
     compares against the new sizes (a maintainer accepting a shrink
     as intentional needs no manual baseline edit).

The output shape matches the conventions the auto-review's other
input streams use — a list of observation dicts the spawned session
folds into its Step 1 surface-state gather.

Source-of-truth choice
----------------------

The integrity check reads PER-SPEC node files (``spec_*.md``), not
the index ``Alethea/specifications/README.md``. Rationale:

  - The per-spec nodes are the canonical post-split form. The
    index is a header-only manifest.
  - Wave 3a is normalizing SPEC-305/306/307 from full-pre-split to
    header-only format in the index; a check that read the index
    would generate false alerts during the normalization. The
    per-spec nodes are NOT shrunk by Wave 3a.

If a future arc consolidates the two sources (or the per-spec node
count drifts from the index count), that's a separate concern — out
of scope here.

State-dir resolution
--------------------

Same precedence as ``route_chat_audit_log.default_state_dir`` (the
Wave 2c pattern Resonance-Website ships):

  1. Explicit ``state_dir`` parameter on the helper.
  2. ``APEIRON_STATE_DIR`` env var, with ``auto_review/`` appended.
  3. ``<apeiron-root>/state/auto_review/`` derived from this file's
     location.

Composes with
-------------

  - ``active_sessions.py`` (SPEC-079) — the discovery-layer pattern
    this module follows.
  - The four existing auto-review input streams documented in
    ``Alethea/session_types/workflow_management.md`` under
    "Auto-review seed prompt — fired by routine:workflow_mgmt_re_review".
  - PR #175 (Apeiron) — the splitter-safety fix that prevents the
    gutting at the splitter level. This module is the
    catch-it-after-the-fact safety net.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------
# Defaults.
# ---------------------------------------------------------------------


#: Default shrink threshold (fraction). A body that shrank by more
#: than this fraction relative to its baseline triggers an alert.
#: 0.5 means "shrunk by more than half".
DEFAULT_SHRINK_THRESHOLD = 0.5

#: Default baseline filename.
DEFAULT_BASELINE_FILENAME = "spec_body_baselines.json"

#: Default Alethea repo relative path (sibling of apeiron-root).
_DEFAULT_ALETHEA_REPO_NAME = "Alethea"

#: Default per-spec node glob (relative to the Alethea repo root).
DEFAULT_SPEC_GLOB = "Alethea-cc/nodes/spec_*.md"


# ---------------------------------------------------------------------
# Public dataclasses.
# ---------------------------------------------------------------------


@dataclass
class SpecBodyAlert:
    """One alert for a SPEC whose body shrunk past the threshold.

    Fields:
        spec_id: SPEC node alias (e.g. ``"spec_001"``).
        path: Absolute path to the node file as observed this run.
        old_lines: Body line count from the baseline file.
        new_lines: Body line count observed this run.
        delta_pct: Shrink as a fraction in [0, 1]
            (``(old - new) / old``). For old=100, new=20 →
            ``delta_pct=0.8`` (the body shrunk by 80%).
    """

    spec_id: str
    path: str
    old_lines: int
    new_lines: int
    delta_pct: float


@dataclass
class IntegrityRunResult:
    """Outcome of one ``run_spec_body_integrity_check`` invocation.

    Fields:
        alerts: SPECs whose bodies crossed the threshold this run.
        observed: Total number of SPEC nodes scanned.
        new_specs: SPEC nodes that weren't in the baseline (no
            comparison possible; recorded with their current
            line count for the next run).
        baseline_updated: True if the baseline file was rewritten
            with the current counts.
        baseline_path: Absolute path to the baseline file.
        first_run: True if no baseline existed prior to this run.
        ts: ISO-8601 UTC timestamp the run completed.
    """

    alerts: List[SpecBodyAlert]
    observed: int
    new_specs: List[str]
    baseline_updated: bool
    baseline_path: str
    first_run: bool
    ts: str


# ---------------------------------------------------------------------
# Public surface.
# ---------------------------------------------------------------------


def default_state_dir() -> Path:
    """Resolve the default ``state/auto_review/`` dir.

    Resolution order matches the Wave 2c convention:

      1. ``APEIRON_STATE_DIR`` env var, with ``auto_review/``
         appended.
      2. ``<apeiron-root>/state/auto_review/`` derived from this
         file's location (``parents[1]`` of ``tools/spec_body_integrity.py``).
    """
    env = os.environ.get("APEIRON_STATE_DIR")
    if env:
        return Path(env) / "auto_review"
    # tools/spec_body_integrity.py → parents[1] is apeiron-root.
    apeiron_root = Path(__file__).resolve().parents[1]
    return apeiron_root / "state" / "auto_review"


def default_alethea_root() -> Optional[Path]:
    """Resolve the sibling Alethea repo root.

    Searches in this order:

      1. ``ALETHEA_ROOT`` env var.
      2. ``<apeiron-root>/../Alethea`` (sibling-on-desktop convention).
      3. Walk up from ``<apeiron-root>`` looking for an ``Alethea``
         child directory — covers the worktree case where the
         apeiron-root is several levels deep.

    Returns ``None`` when no Alethea checkout can be found; callers
    treat this as "no SPECs to check this run, no alerts".
    """
    env = os.environ.get("ALETHEA_ROOT")
    if env:
        p = Path(env)
        if p.exists():
            return p
        # Env var pointed at a non-existent path → fall through to
        # the heuristic search rather than crash; the env var is a
        # hint, not an oath.
    apeiron_root = Path(__file__).resolve().parents[1]
    sibling = apeiron_root.parent / _DEFAULT_ALETHEA_REPO_NAME
    if sibling.exists():
        return sibling
    # Walk up looking for an Alethea sibling — covers the worktree
    # case (apeiron-root may be ``.../Apeiron/.worktrees/<branch>``;
    # the Alethea sibling is at ``.../Alethea``).
    for parent in [apeiron_root, *apeiron_root.parents]:
        cand = parent.parent / _DEFAULT_ALETHEA_REPO_NAME
        if cand.exists() and (cand / "Alethea-cc").exists():
            return cand
    return None


def run_spec_body_integrity_check(
    *,
    state_dir: Optional[Path] = None,
    alethea_root: Optional[Path] = None,
    baseline_filename: str = DEFAULT_BASELINE_FILENAME,
    shrink_threshold: float = DEFAULT_SHRINK_THRESHOLD,
    spec_glob: str = DEFAULT_SPEC_GLOB,
    update_baseline: bool = True,
) -> IntegrityRunResult:
    """Run one pass of the SPEC body integrity check.

    The fifth input stream for the workflow-management auto-review.
    Reads per-spec node files, computes line-count deltas vs the
    baseline, flags shrinks past the threshold, and updates the
    baseline file (when ``update_baseline=True``).

    Parameters
    ----------
    state_dir
        Where the baseline JSON lives. When ``None``, resolves via
        ``default_state_dir()``.
    alethea_root
        Path to the sibling Alethea repo. When ``None``, resolves
        via ``default_alethea_root()``. When the resolver returns
        ``None``, the run returns immediately with an empty
        observation set + ``observed=0`` — better to no-op than to
        emit false alerts.
    baseline_filename
        Basename of the baseline JSON file. Defaults to
        ``"spec_body_baselines.json"``.
    shrink_threshold
        Alert when ``(old - new) / old`` exceeds this fraction.
        Defaults to 0.5 (alert on >50% shrink). Pass 1.0 to alert
        only on complete deletion; pass 0.0 to alert on any
        shrinkage (noisy — not recommended).
    spec_glob
        Glob pattern relative to ``alethea_root``. Defaults to
        ``"Alethea-cc/nodes/spec_*.md"``.
    update_baseline
        Rewrite the baseline file with the current counts when
        ``True`` (the default). Pass ``False`` for a read-only
        probe — tests use this to verify alerts fire without
        side-effecting subsequent runs.

    Returns
    -------
    An ``IntegrityRunResult`` with the alerts + run metadata.
    Never raises into the caller (the auto-review session calls
    this from inside its turn; an exception would abort the pass).
    """
    resolved_state_dir = (
        Path(state_dir) if state_dir is not None else default_state_dir()
    )
    resolved_alethea = (
        Path(alethea_root) if alethea_root is not None else default_alethea_root()
    )

    ts = _now_iso()
    baseline_path = resolved_state_dir / baseline_filename

    if resolved_alethea is None or not resolved_alethea.exists():
        # No Alethea checkout reachable — return empty result. The
        # auto-review session can fold "no SPEC integrity check ran
        # this pass" into its summary without crashing.
        return IntegrityRunResult(
            alerts=[],
            observed=0,
            new_specs=[],
            baseline_updated=False,
            baseline_path=str(baseline_path),
            first_run=not baseline_path.exists(),
            ts=ts,
        )

    spec_files = sorted(resolved_alethea.glob(spec_glob))
    current_counts = {
        _spec_id_from_path(p): _count_body_lines(p) for p in spec_files
    }

    baseline = _load_baseline(baseline_path)
    first_run = baseline is None
    baseline_counts: Dict[str, int] = baseline.get("counts", {}) if baseline else {}

    alerts: List[SpecBodyAlert] = []
    new_specs: List[str] = []
    for spec_id, new_lines in current_counts.items():
        old_lines = baseline_counts.get(spec_id)
        if old_lines is None:
            # New SPEC since last run — no baseline to compare; the
            # next run picks this up as the comparison target.
            new_specs.append(spec_id)
            continue
        if old_lines <= 0:
            # Baseline recorded zero or negative — can't compute a
            # delta. Skip silently; the next run picks up the
            # current count as the new baseline.
            continue
        delta = (old_lines - new_lines) / old_lines
        if delta > shrink_threshold:
            alerts.append(
                SpecBodyAlert(
                    spec_id=spec_id,
                    path=str(next(
                        p for p in spec_files
                        if _spec_id_from_path(p) == spec_id
                    )),
                    old_lines=old_lines,
                    new_lines=new_lines,
                    delta_pct=round(delta, 4),
                )
            )

    baseline_updated = False
    if update_baseline:
        baseline_updated = _save_baseline(
            baseline_path,
            counts=current_counts,
            ts=ts,
            shrink_threshold=shrink_threshold,
        )

    return IntegrityRunResult(
        alerts=alerts,
        observed=len(current_counts),
        new_specs=sorted(new_specs),
        baseline_updated=baseline_updated,
        baseline_path=str(baseline_path),
        first_run=first_run,
        ts=ts,
    )


def render_alerts(result: IntegrityRunResult) -> List[Dict[str, Any]]:
    """Project an ``IntegrityRunResult`` onto the observation-dict
    shape the auto-review's Step 1 gather expects.

    Each alert becomes one observation::

        {"source":      "spec_body_integrity",
         "kind":        "alert",
         "spec_id":     "<spec_id>",
         "path":        "<abs path>",
         "old_lines":   <int>,
         "new_lines":   <int>,
         "delta_pct":   <float in [0, 1]>,
         "message":     "<human-readable summary>"}

    Returns an empty list when no alerts fired this run. Callers
    fold the returned list into their other gather output.
    """
    out: List[Dict[str, Any]] = []
    for alert in result.alerts:
        out.append({
            "source": "spec_body_integrity",
            "kind": "alert",
            "spec_id": alert.spec_id,
            "path": alert.path,
            "old_lines": alert.old_lines,
            "new_lines": alert.new_lines,
            "delta_pct": alert.delta_pct,
            "message": (
                f"SPEC body shrunk {int(alert.delta_pct * 100)}% "
                f"(from {alert.old_lines} to {alert.new_lines} lines) "
                f"at {alert.spec_id}"
            ),
        })
    return out


# ---------------------------------------------------------------------
# Internals.
# ---------------------------------------------------------------------


_SPEC_ID_RE = re.compile(r"^(spec_\d+)")


def _spec_id_from_path(path: Path) -> str:
    """Derive the SPEC alias from the filename stem.

    Per the convention in ``Alethea-cc/nodes/spec_<N>_<slug>.md``,
    the spec alias is the leading ``spec_<N>`` portion. Falls back
    to the full stem when the regex doesn't match (defensive — no
    spec on disk today has a non-matching name).
    """
    m = _SPEC_ID_RE.match(path.stem)
    if m:
        return m.group(1)
    return path.stem


def _count_body_lines(path: Path) -> int:
    """Count non-frontmatter lines in a SPEC node file.

    Body = everything AFTER the closing ``---`` of the YAML
    frontmatter. When the file has no frontmatter (rare for SPEC
    nodes, but defensive), the full file is treated as body.
    Blank lines + comment lines are counted (the gutting check is
    about total content displacement, not non-trivial content).
    """
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return 0
    # Detect frontmatter via the opening ``---\n`` marker.
    if not text.startswith("---\n") and not text.startswith("---\r\n"):
        return len(text.splitlines())
    # Find the closing ``---`` after the opening one.
    # ``text.find("\n---\n", 4)`` matches the next standalone marker.
    close_idx = text.find("\n---\n", 4)
    if close_idx == -1:
        close_idx = text.find("\n---\r\n", 4)
    if close_idx == -1:
        # Malformed frontmatter — treat the whole file as body so
        # we don't hide a destroyed file by ignoring it entirely.
        return len(text.splitlines())
    body = text[close_idx + len("\n---\n"):]
    return len(body.splitlines())


def _load_baseline(path: Path) -> Optional[Dict[str, Any]]:
    """Load the baseline JSON. Returns ``None`` on first run + on
    any read/parse failure (the next run replaces the baseline).
    """
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _save_baseline(
    path: Path,
    *,
    counts: Dict[str, int],
    ts: str,
    shrink_threshold: float,
) -> bool:
    """Write the baseline JSON. Returns True on success, False on
    any failure (the auto-review pass keeps going; the next run
    retries the write).

    The baseline payload includes the run timestamp + the active
    threshold so a maintainer reading the file can see when the
    last update fired + what threshold the alerts were computed
    against.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "ts": ts,
            "shrink_threshold": shrink_threshold,
            "counts": dict(counts),
        }
        # Sort the counts so commits land deterministically (helpful
        # when the baseline file is checked into git).
        payload["counts"] = {k: counts[k] for k in sorted(counts)}
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=False) + "\n",
            encoding="utf-8",
        )
        return True
    except Exception:
        return False


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------------------------------------------------------------------
# CLI entry-point — for manual probing + cron + the routine_pump.
# ---------------------------------------------------------------------


def _main() -> int:
    """CLI: run the check + print the alert list as JSON.

    Usage::

        python tools/spec_body_integrity.py [--no-baseline-update]
                                            [--threshold 0.5]
                                            [--alethea-root PATH]
                                            [--state-dir PATH]

    Exit code:
      0 — no alerts (or first run / no Alethea reachable).
      1 — at least one alert fired.
      2 — bad CLI args.
    """
    import argparse

    parser = argparse.ArgumentParser(
        description="Run the SPEC body integrity check.",
    )
    parser.add_argument(
        "--no-baseline-update",
        action="store_true",
        help="Don't rewrite the baseline file (read-only probe).",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_SHRINK_THRESHOLD,
        help=(
            "Shrink fraction that triggers an alert (default 0.5 = "
            "alert on >50%% shrink)."
        ),
    )
    parser.add_argument(
        "--alethea-root",
        type=Path,
        default=None,
        help="Override the sibling Alethea repo path.",
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=None,
        help="Override the baseline-file directory.",
    )
    try:
        args = parser.parse_args()
    except SystemExit:
        return 2

    result = run_spec_body_integrity_check(
        state_dir=args.state_dir,
        alethea_root=args.alethea_root,
        shrink_threshold=args.threshold,
        update_baseline=not args.no_baseline_update,
    )
    output = {
        "ts": result.ts,
        "observed": result.observed,
        "first_run": result.first_run,
        "baseline_updated": result.baseline_updated,
        "baseline_path": result.baseline_path,
        "new_specs": result.new_specs,
        "alerts": [asdict(a) for a in result.alerts],
        "observations": render_alerts(result),
    }
    print(json.dumps(output, indent=2))
    return 1 if result.alerts else 0


if __name__ == "__main__":
    raise SystemExit(_main())
