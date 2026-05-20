"""
Browser tool primitives — SPEC-066.

A thin wrapper around ``tkinterweb`` for loading URLs / HTML strings
into an ``HtmlFrame`` widget. The wrapper is split out from the
node-type so callers that just want to display a page in an ad-hoc Tk
frame (without spinning up an Engine + scene) can do::

    from tools.browser import open_url, open_html
    widget = open_url(parent, "https://example.com")

The same primitives back the ``BrowserRenderer`` node-type's
``precompute_hook`` and ``emit`` paths and the GUI shell's ``web``
view kind, so the three surfaces stay in sync.

tkinterweb at a glance
----------------------

* ``HtmlFrame`` IS a ``tk.Frame`` subclass — it embeds the same way
  ``ListRenderer``'s Treeview does.
* ``load_url(url)`` blocks on a network fetch and returns when the
  document has loaded. The widget keeps a background thread for any
  subsequent navigation events.
* ``load_html(html_string)`` does no network I/O — useful for tests
  + offline rendering. Same widget either way.
* ``current_url`` is exposed via ``frame.current_url`` (string) once
  a page has loaded.

Dependency policy
-----------------

The import is lazy + try/except so a missing tkinterweb degrades
gracefully:

* ``is_available()`` returns ``True`` only when import + headless
  instantiation both succeed.
* ``open_url`` / ``open_html`` raise :class:`BrowserUnavailableError`
  with a helpful message when tkinterweb isn't importable.

The ready-check probe (``ready_check._check_browser``) uses
``is_available()`` to surface the missing-dep state without crashing.

Trust gate composition (SPEC-054)
---------------------------------

This module does NOT bypass the engine's render-trust gate. Pasted
``BrowserRenderer`` nodes still flow through ``Engine.discover`` ->
``trust_set.is_trusted(source_id)``; an untrusted paste produces the
usual dead-node placeholder. This module only provides the widget
primitive — gating happens at the node-type discovery surface.
"""

from __future__ import annotations

from typing import Any, Optional


class BrowserUnavailableError(RuntimeError):
    """Raised when tkinterweb is not installed / not importable.

    The error message names the install command so callers (test
    surfaces, the GUI shell, ready-check) can route the maintainer to
    a one-line fix without consulting the design doc.
    """


def is_available() -> bool:
    """Return True iff tkinterweb is importable AND HtmlFrame can be
    instantiated headless-safe.

    The probe is conservative: a single ``import tkinterweb`` is not
    enough — the wheel can install while the bundled Tkhtml binary is
    missing on platforms tkinterweb-tkhtml doesn't ship a wheel for.
    The instantiation check catches that case.

    Headless-safe means: tries to construct an HtmlFrame against a
    withdrawn Tk root; on any error returns False rather than raising.
    Safe to call from a CI runner with no display.
    """
    try:
        import tkinter as tk
        from tkinterweb import HtmlFrame  # noqa: F401
    except Exception:
        return False

    try:
        root = tk.Tk()
        try:
            root.withdraw()
        except Exception:
            pass
        try:
            frame = HtmlFrame(root, messages_enabled=False)
            frame.destroy()
        finally:
            root.destroy()
    except Exception:
        return False
    return True


def open_url(parent: Any, url: str, *, messages_enabled: bool = False) -> Any:
    """Construct an ``HtmlFrame`` packed inside ``parent`` and load
    ``url``. Returns the frame so the caller can ``pack()``/``place()``
    it or destroy it later.

    Raises :class:`BrowserUnavailableError` if tkinterweb is missing.
    Network / load errors propagate as tkinterweb's own exception
    types (typically subclasses of ``Exception`` from urllib).
    """
    HtmlFrame = _require_html_frame()
    frame = HtmlFrame(parent, messages_enabled=messages_enabled)
    if url:
        frame.load_url(url)
    return frame


def open_html(parent: Any, html: str, *, messages_enabled: bool = False) -> Any:
    """Construct an ``HtmlFrame`` packed inside ``parent`` and render
    ``html`` (no network I/O).

    Useful for tests + the ``html_string`` override on
    ``BrowserRenderer``. Returns the frame so the caller controls
    layout + lifetime.
    """
    HtmlFrame = _require_html_frame()
    frame = HtmlFrame(parent, messages_enabled=messages_enabled)
    if html:
        frame.load_html(html)
    return frame


def current_url(frame: Any) -> Optional[str]:
    """Return the URL currently displayed by ``frame``, or None when
    no page is loaded / the frame doesn't expose ``current_url``.

    tkinterweb exposes ``HtmlFrame.current_url`` as a string property.
    On older builds the attribute may be absent; this helper smooths
    over the difference so callers don't have to ``hasattr`` check.
    """
    url = getattr(frame, "current_url", None)
    if url is None:
        return None
    s = str(url).strip()
    return s or None


def _require_html_frame():
    try:
        from tkinterweb import HtmlFrame
    except Exception as exc:
        raise BrowserUnavailableError(
            "tkinterweb is not installed. Install with: "
            "pip install \"tkinterweb>=4.25.2,<5\""
        ) from exc
    return HtmlFrame


__all__ = [
    "BrowserUnavailableError",
    "current_url",
    "is_available",
    "open_html",
    "open_url",
]
