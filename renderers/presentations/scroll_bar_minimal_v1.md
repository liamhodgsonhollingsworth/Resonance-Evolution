---
id: scroll_bar_minimal_v1
kind: renderer
name: scroll_bar_minimal_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: ScrollBarNode
text: Minimal raster variant of the ScrollBarNode primitive (N-F023). Thin centered track with a small thumb at the fractional position. The default look for headless tests and the function/visual proof per Decision A1 of brief 03's per-module plan.
---

```json
{
  "name": "scroll_bar_minimal_v1",
  "description": "Minimal raster scroll-bar: thin track + small thumb at the value's fractional position.",
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
            "orientation": {"type": "string"},
            "screen_width": {"type": "number"},
            "screen_height": {"type": "number"},
            "screen_resolution": {"type": "integer"}
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
    "path": "renderers/presentations/scroll_bar_minimal_v1.py",
    "callable": "render"
  }
}
```

# scroll_bar_minimal_v1

The minimal-style variant of the scroll-bar functional primitive. Renders a thin centered track strip with a small thumb at the fractional position determined by ``(value - min) / (max - min)``.

Per SPEC-090's 1:N functional/visual binding: this variant is one of several ways a ``ScrollBarNode`` can be presented. The functional state (``min``, ``max``, ``value``, ``orientation``) determines what the variant shows; the variant determines how. Two other variants ship alongside in brief 03 commit 3: ``scroll_bar_chunky_v1`` (a thicker, more tactile look) and ``scroll_bar_thin_v1`` (a hairline rail).

Swapping variants via the ``ScrollBarNode``'s ``displayed_by`` field changes the visual without touching the functional state — the same value at the same orientation renders differently across variants. This is the function/visual contract proof: Scenario 2 of the per-module plan's plan-testing scenarios.
