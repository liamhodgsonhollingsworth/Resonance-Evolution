"""Toolbox-as-default inference rules registry (Decision A2).

Brief 03 commit 2 of the Resonance website implementation arc — the
fixed registry naming which typed-kind a toolbox flips into when its
first ``as: rendered`` child is added. Decision A2 verbatim:

  - First child is ``kind: TextDisplayNode`` → ``kind: TextBoxNode``.
  - First child is ``kind: SliderNode``      → ``kind: ControlPanelNode``.
  - First child is ``kind: ButtonNode``      → ``kind: ButtonBarNode``.
  - First child is ``kind: ImageNode``       → ``kind: ImageFrameNode``.
  - Otherwise → stays a toolbox; the maintainer can supersede later
    via the GUI builder or an explicit substrate supersession.

The registry is monotonic-extensible: sessions add new entries via
``register(first_child_kind, typed_kind, reason)``; existing entries
are immutable (re-registration with a different typed-kind raises).
This honours the architectural-commitment #6 (monotonic substrate
extensions) AND the per-module plan's Decision A2 tradeoff: *"sessions
can extend it but cannot break existing entries."*

The file name is underscore-prefixed so ``Engine.discover()`` skips
it (per the convention in ``engine.core.Engine._load_node_type_file``
which excludes ``_*.py``); the module is consumed by ``toolbox.py``
via direct import.

Phase-1 only registers the four kinds Decision A2 names. Commits 3-7
register additional kinds (e.g., scroll-bar onto a toolbox → its own
typed-kind) as those primitives land.
"""

from __future__ import annotations

from typing import Dict, Optional


# Frozen-by-convention registry. Entries are immutable once added; the
# ``register`` helper enforces that. Phase-1 entries from Decision A2.
_INFERENCE_RULES: Dict[str, str] = {
    "TextDisplayNode": "TextBoxNode",
    "SliderNode": "ControlPanelNode",
    "ButtonNode": "ButtonBarNode",
    "ImageNode": "ImageFrameNode",
}


# Per-rule reason strings — surface them in the auto-flip log entry so
# future maintainers reading the supersession chain can see WHY the
# toolbox flipped, not just WHAT it flipped into.
_INFERENCE_REASONS: Dict[str, str] = {
    "TextDisplayNode": "first text-display child triggered text-box typed kind",
    "SliderNode": "first slider child triggered control-panel typed kind",
    "ButtonNode": "first button child triggered button-bar typed kind",
    "ImageNode": "first image child triggered image-frame typed kind",
}


def infer_typed_kind(first_child_kind: str) -> Optional[str]:
    """Look up the typed-kind a toolbox should flip into.

    Returns ``None`` when no rule matches — caller leaves the toolbox
    as a toolbox and writes an "ambiguous toolbox content" log entry
    per Decision A2's tradeoff.
    """
    return _INFERENCE_RULES.get(first_child_kind)


def reason_for(first_child_kind: str) -> Optional[str]:
    """Return the human-readable reason string for the matched rule,
    or None if no rule matches. Used by the supersession metadata to
    annotate why a toolbox flipped."""
    return _INFERENCE_REASONS.get(first_child_kind)


def register(first_child_kind: str, typed_kind: str, reason: str) -> None:
    """Register a new inference rule.

    Monotonic: re-registering with a DIFFERENT ``typed_kind`` raises
    ``ValueError`` so a downstream commit can't silently change what
    a published toolbox would have flipped into. Re-registering with
    the SAME ``typed_kind`` is a no-op (the reason updates only if
    the entry was missing one).
    """
    if not first_child_kind or not isinstance(first_child_kind, str):
        raise ValueError(
            f"register requires a non-empty string first_child_kind; "
            f"got {first_child_kind!r}"
        )
    if not typed_kind or not isinstance(typed_kind, str):
        raise ValueError(
            f"register requires a non-empty string typed_kind; "
            f"got {typed_kind!r}"
        )
    existing = _INFERENCE_RULES.get(first_child_kind)
    if existing is not None and existing != typed_kind:
        raise ValueError(
            f"register: inference rule for {first_child_kind!r} already "
            f"maps to {existing!r}; refusing to remap to {typed_kind!r}. "
            f"Inference rules are monotonic (Decision A2)."
        )
    _INFERENCE_RULES[first_child_kind] = typed_kind
    # Reason update is conservative: only set when there isn't one
    # already (so the canonical reasons declared at module-init survive
    # a downstream idempotent re-register that supplies a less-useful
    # reason string).
    if reason and not _INFERENCE_REASONS.get(first_child_kind):
        _INFERENCE_REASONS[first_child_kind] = str(reason)


def known_kinds() -> list[str]:
    """Return the sorted list of source kinds with registered rules.
    Useful for diagnostics + test enumeration."""
    return sorted(_INFERENCE_RULES.keys())
