# Steampunk stool — interactive 3D mockup

Dropped-work-recovery item 3. Liam (Discord `#dev`, msg `1526751917060128809`,
2026-07-15T00:47:02Z), verbatim:

> For the mockups of these basic 3D models, include links to single webpages
> where I can maneuver around in 3D and interact with the artifact, as well
> as adjusting the parameters of the artifact to change it around (the
> parameters should be adjustable in a separate window within the browser tab
> or a popout window, either option should be separate wirable node based
> options

## What this is

A real, working single webpage where you can:

- **Maneuver around in 3D** — orbit / pan / zoom (three.js `OrbitControls`).
- **Interact with the artifact** — click a part (a leg, the seat, a stretcher
  pipe, a tee junction, a floor flange) to highlight it and see its name.
- **Adjust the artifact's parameters live** — every real dimension of the
  steampunk pipe stool (seat radius/thickness, leg radius/wall/height, leg
  spread, stretcher-ring height) is a slider wired to the REAL proc3d
  generator, regenerating a REAL `.glb` on every change.

The tuning panel is available in **both** modes named in the spec, selectable
from one dropdown (never hardcoded to one):

- **Embedded** — a docked, draggable panel that is a genuinely separate
  `<iframe>` document within the same browser tab.
- **Popout** — a real `window.open()` popout window.

Both modes load the exact same `tuner.html` and publish over the exact same
`ws://` `param_channel` room — one underlying wiring, two presentation
contexts.

## Run it

```
py server.py
```

Then open `http://127.0.0.1:8791/index.html`. The popout/embedded tuning
panel is `http://127.0.0.1:8791/tuner.html`.

If the server isn't running, `index.html` still loads and lets you orbit the
committed static reference model (`assets/stool_default.glb`) — live tuning
is unavailable until `py server.py` is started, and the page says so.

## How it's wired

- **3D artifact**: `tools/stool_tunable.py` reuses Wavelet's real proc3d
  primitives (`parametric_part.py` / `parts.py` / `assembly.py` /
  `linalg.py` / `gear_gen.py`, cross-repo import) to build the SAME steampunk
  pipe stool `Alethea-cc/tools/proc3d/targets/stool.py` builds, but with
  every dimension read from a `params` dict instead of a module constant.
  `targets/stool.py` itself is never edited.
- **GLB export**: the CANONICAL proc3d exporter,
  `Alethea-cc/tools/proc3d/glb_export.py` (PR #934, `assembly_to_glb`) — this
  page does not carry its own GLB writer.
- **Live parameter transport**: Wavelet's real `param_channel` /
  `ws://` substrate (`projection/graph/param_channel_node.py` +
  `projection/transport/ws_relay_server.py`, PR #910). `server.py` runs the
  relay AND a `param_channel` "demo window" consumer that drains it
  (last-write-wins, `param_channel_latest()`) and regenerates/re-exports the
  `.glb` on every change. Any browser tab (embedded panel or popout) is a
  "tuning window" publishing the exact `{"param","value","ts"}` wire shape
  `param_channel_node.py` already defines — no second protocol.

## Files

- `server.py` — the one process: ws relay + param_channel consumer + regen
  loop + static file server.
- `index.html` / `static/viewer.js` — the 3D viewer ("demo window").
- `tuner.html` / `static/tuner.js` — the tuning panel content, used by both
  the embedded iframe and the popout window.
- `tools/stool_tunable.py` — the parameterized stool generator.
- `assets/stool_default.glb` — the committed static reference GLB (default
  params, exported via the canonical exporter), used as the no-server-running
  fallback.
- `tests/test_stool_tunable.py` — standalone smoke tests (`py
  tests/test_stool_tunable.py`).

## Follow-ups (not built here — enqueued separately)

- Single-URL-scheme integration with `Alethea-cc/tools/discord_relay/
  artifact_pages.py` (PR #923) so a Discord-linked artifact page upgrades
  into this viewer for 3D-capable lanes, instead of linking out to a
  separately-run RE dev server. See the Wavelet-side PR for the additive
  `interactive_3d` hook this page's bundle is designed to be copied into.
- A second artifact (`targets/wall_display.py`) could get the same
  treatment; only the stool was built here to prove the end-to-end pattern
  end-to-end with one real artifact, per the dispatching task's own scope.
