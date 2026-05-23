---
id: video_default_v1
kind: renderer
name: video_default_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: VideoNode
text: Default raster variant of the VideoNode primitive (N-F026). Renders the first-frame preview via imageio when available; falls back to placeholder + alt-text overlay otherwise. The HTML variant produces a real <video> element consuming the same playback state; this raster variant is the headless-test default per Decision A1 of brief 03's per-module plan.
---

```json
{
  "name": "video_default_v1",
  "description": "Default raster video variant: first-frame preview via imageio (optional); placeholder + alt-text overlay when decode is unavailable.",
  "input": {
    "schema": {
      "type": "object",
      "properties": {
        "primitive_state": {
          "type": "object",
          "properties": {
            "src": {"type": "string"},
            "alt_text": {"type": "string"},
            "autoplay": {"type": "boolean"},
            "loop": {"type": "boolean"},
            "controls": {"type": "boolean"},
            "screen_width": {"type": "number"},
            "screen_height": {"type": "number"},
            "screen_resolution": {"type": "integer"}
          },
          "required": ["src"]
        },
        "context": {"type": "object"}
      },
      "required": ["primitive_state"]
    }
  },
  "output": {"schema": {"type": "object", "format": "rgb-float32-array"}},
  "implementation": {
    "kind": "python-callable",
    "path": "renderers/presentations/video_default_v1.py",
    "callable": "render"
  }
}
```

# video_default_v1

The default raster variant of VideoNode. Renders the first-frame preview via imageio when the optional dependency is installed; falls back to a placeholder rectangle + the alt-text overlay otherwise. Caches the extracted first frame at ``Apeiron/state/video_first_frames/`` so repeated emits don't re-decode.

The HTML variant (Resonance-Website side) produces a real ``<video>`` element consuming the same playback state (autoplay/loop/controls). Both variants compose through the same ``displayed_by`` slot — switching surfaces is a node-graph operation per Decision A1.
