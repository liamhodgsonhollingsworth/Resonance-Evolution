---
id: slider_chunky_v1
kind: renderer
name: slider_chunky_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: SliderNode
text: Chunky raster slider variant — full-height track with a large square thumb (~25% of the long axis). Visually weighty for primary-control surfaces.
---

```json
{
  "name": "slider_chunky_v1",
  "description": "Chunky slider: full-height track + large square thumb.",
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
    "path": "renderers/presentations/slider_chunky_v1.py",
    "callable": "render"
  }
}
```

# slider_chunky_v1

The chunky-style slider — full-height track + a substantial square thumb. Use for primary control surfaces where the slider must feel grabbable.
