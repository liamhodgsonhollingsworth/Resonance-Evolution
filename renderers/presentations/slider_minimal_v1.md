---
id: slider_minimal_v1
kind: renderer
name: slider_minimal_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: SliderNode
text: Minimal raster variant of the SliderNode primitive (N-F025). Thin centered track with a small thumb at the value's fractional position. Aspect-aware orientation (horizontal default).
---

```json
{
  "name": "slider_minimal_v1",
  "description": "Minimal slider: thin track + small thumb at the value position.",
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
            "step": {"type": "number"},
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
    "path": "renderers/presentations/slider_minimal_v1.py",
    "callable": "render"
  }
}
```

# slider_minimal_v1

The minimal-style variant of the slider functional primitive. Identical functional state to the chunky and knob variants — only the rendering differs. Used as the default presentation when no ``displayed_by`` is set on the SliderNode.
