---
id: scroll_bar_thin_v1
kind: renderer
name: scroll_bar_thin_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: ScrollBarNode
text: Thin hairline-rail raster variant of the ScrollBarNode primitive. A 1-pixel rail with a small accent at the value's fractional position. The most minimal possible scroll indicator.
---

```json
{
  "name": "scroll_bar_thin_v1",
  "description": "Thin hairline-rail scroll-bar variant: 1px track + small accent thumb.",
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
    "path": "renderers/presentations/scroll_bar_thin_v1.py",
    "callable": "render"
  }
}
```

# scroll_bar_thin_v1

The hairline variant — a single-pixel rail at the centerline of the long axis with a small accent at the thumb position. Use when the scroll-bar should be present-but-invisible (the reader knows it's there if they look). Same functional state as the other variants.
