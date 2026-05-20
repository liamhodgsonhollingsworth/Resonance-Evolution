"""
Baseline manifest — SPEC-080.

A registry mapping baseline-name -> renderer hook, plus the metadata
the runner needs to capture, compare, and report. SPEC-069 wires
real renderer hooks against the production workflow views; this
module owns the manifest data structure and an in-memory registry
that's empty by default (scaffolding only — no production baselines
ship with this PR).

Design choices:

- ``BaselineSpec`` is a frozen dataclass so manifests are easy to pass
  around and compare equality without aliasing surprises.
- ``BaselineManifest`` exposes a small mutating surface
  (``register``, ``unregister``) for SPEC-069 to populate. Tests
  build their own manifests in-line; production code constructs one
  per process via :func:`default_manifest`.
- The renderer hook signature is ``() -> tk_widget``. The hook is
  responsible for setting up Tk + driving the GUI to the target
  state; the runner only calls the hook and captures the widget it
  returns.
- ``threshold`` is per-baseline so noisier scenes (timestamps, 3D
  canvases) can opt into a looser threshold without affecting the
  rest of the suite.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterable, List, Optional


@dataclass(frozen=True)
class BaselineSpec:
    """Description of a registered baseline.

    Attributes:
        name: Slug used as the PNG filename
            (``baselines/<name>.png``). Should match
            ``[A-Za-z0-9_]+`` so it's path-safe on every platform.
        renderer: Callable that returns the Tk widget to capture.
            The runner invokes this when SPEC-069 lands real scenes;
            scaffolding tests pass a stub callable.
        description: Human-readable purpose; surfaces in
            ``visual-regression-list`` output.
        threshold: SSIM threshold for this baseline. Defaults to None,
            meaning "use the runner's default" (which is
            ``compare.DEFAULT_SSIM_THRESHOLD`` = 0.98).
        tags: Free-form labels (e.g. ``"2d"``, ``"3d"``, ``"flaky"``)
            for future filtering.
    """

    name: str
    renderer: Callable[[], Any]
    description: str = ""
    threshold: Optional[float] = None
    tags: tuple = field(default=())


class BaselineManifest:
    """Mutable registry of :class:`BaselineSpec` entries.

    Keyed by ``name``. The text-API verbs (SPEC-081 obligation) plus
    the runner consult this registry to know what's registered. A
    fresh manifest is empty — SPEC-069 populates production entries
    once the GUI surfaces stabilise.
    """

    def __init__(self) -> None:
        self._entries: Dict[str, BaselineSpec] = {}

    def register(self, spec: BaselineSpec) -> None:
        """Add or replace a baseline registration.

        Raises:
            ValueError: If the name is not a valid slug.
        """
        if not spec.name or not spec.name.replace("_", "").replace("-", "").isalnum():
            raise ValueError(
                f"baseline name {spec.name!r} is not slug-safe; "
                f"use [A-Za-z0-9_-]+"
            )
        self._entries[spec.name] = spec

    def unregister(self, name: str) -> bool:
        """Remove a baseline; returns True if it was present."""
        return self._entries.pop(name, None) is not None

    def get(self, name: str) -> Optional[BaselineSpec]:
        return self._entries.get(name)

    def names(self) -> List[str]:
        return sorted(self._entries.keys())

    def list_specs(self) -> List[BaselineSpec]:
        return [self._entries[n] for n in self.names()]

    def __len__(self) -> int:
        return len(self._entries)

    def __contains__(self, name: str) -> bool:
        return name in self._entries

    def __iter__(self) -> Iterable[BaselineSpec]:
        return iter(self.list_specs())


# Module-level singleton — created lazily so tests can swap it.
_DEFAULT: Optional[BaselineManifest] = None


def default_manifest() -> BaselineManifest:
    """Return the process-wide default manifest.

    SPEC-069 will call ``default_manifest().register(...)`` at import
    time for production scenes. Tests should construct their own
    :class:`BaselineManifest` rather than mutating this one to avoid
    cross-test interference.
    """
    global _DEFAULT
    if _DEFAULT is None:
        _DEFAULT = BaselineManifest()
    return _DEFAULT


def reset_default_manifest() -> None:
    """Drop the cached default manifest. Test-only — exposed so
    tests can guarantee a clean slate without touching globals
    directly."""
    global _DEFAULT
    _DEFAULT = None
