---
id: scroll_bar_chunky_v1
kind: renderer
name: scroll_bar_chunky_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: ScrollBarNode
text: Chunky raster variant of the ScrollBarNode primitive — full-bleed track with a tactile rectangular thumb taking ~40% of the long axis. Drawn with thicker borders. Same functional state as the minimal variant; visually heavier, intentionally over-built.
---

```json
{
  "name": "scroll_bar_chunky_v1",
  "description": "Chunky raster scroll-bar: full-bleed track + large rectangular thumb. Visually weighty alternative to the minimal variant.",
  "input": {
    "schema": {
      "type": "object",
      "properties": {
        "primitive_state": {
          "type": "object",
          "properties": {
            "min": {"type": "number"},
            "max": {"type": "number"},
            "value": {"type": "number"},
            "orientation": {"type": "string"}
          },
          "required": ["min", "max", "value", "orientation"]
        },
        "context": {"type": "object"}
      },
      "required": ["primitive_state"]
    }
  },
  "output": {"schema": {"type": "object", "format": "rgb-float32-array"}},
  "implementation": {
    "kind": "python-callable",
    "path": "renderers/presentations/scroll_bar_chunky_v1.py",
    "callable": "render"
  }
}
```

# scroll_bar_chunky_v1

The chunky-style variant of the scroll-bar functional primitive. Full-bleed track + a large rectangular thumb (~40% of the long axis), drawn with a 2px outline for tactile contrast. Same functional state as the minimal variant; the visual identity is "this is a real thing you grab" rather than "this is a hint at scroll position."

Per SPEC-090 + per the per-module plan's Decision A1: the function (where the value sits, what the range is) is identical across variants; the rendering is the variant's responsibility. Use this variant when the scroll-bar deserves visual weight (e.g. the primary navigation control on a page); use ``scroll_bar_minimal_v1`` when it should fade into the layout.
