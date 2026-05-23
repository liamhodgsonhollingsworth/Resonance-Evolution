---
id: dropdown_chunky_v1
kind: renderer
name: dropdown_chunky_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: DropdownNode
text: Chunky raster dropdown — open-form, showing the selected option highlighted plus a vertical stack of the alternatives. Visually heavier; useful for short option lists.
---

```json
{
  "name": "dropdown_chunky_v1",
  "description": "Chunky dropdown: open-form vertical list with selected option highlighted.",
  "input": {
    "schema": {
      "type": "object",
      "properties": {
        "primitive_state": {
          "type": "object",
          "properties": {
            "options": {"type": "array"},
            "selected": {"type": "string"}
          },
          "required": ["options", "selected"]
        },
        "context": {"type": "object"}
      },
      "required": ["primitive_state"]
    }
  },
  "output": {"schema": {"type": "object", "format": "rgb-float32-array"}},
  "implementation": {
    "kind": "python-callable",
    "path": "renderers/presentations/dropdown_chunky_v1.py",
    "callable": "render"
  }
}
```

# dropdown_chunky_v1

Open-form vertical-list variant. Shows the full option list with the selected option highlighted. Same functional state as the minimal variant — uses ``options`` + ``selected`` directly. Use for short option lists where the alternatives should always be visible.
