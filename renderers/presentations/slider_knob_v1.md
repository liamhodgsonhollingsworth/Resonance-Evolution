---
id: slider_knob_v1
kind: renderer
name: slider_knob_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: SliderNode
text: Knob raster variant — circular thumb rolling along the track. Visually expresses "rotational control" even on a linear primitive. Per N-F025 ``Risk + mitigation`` the same functional state drives a circular knob just as well as a rectangular thumb.
---

```json
{
  "name": "slider_knob_v1",
  "description": "Knob slider: circular thumb on a thin track.",
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
    "path": "renderers/presentations/slider_knob_v1.py",
    "callable": "render"
  }
}
```

# slider_knob_v1

The knob variant — a circular thumb traverses the track. Functional state identical to the minimal + chunky variants; the visual reframe ("this is a knob") is the whole point of the variant. Composable with future ``TuningKnobNode`` work (per the architectural-extensions doc) without changing the underlying SliderNode.
