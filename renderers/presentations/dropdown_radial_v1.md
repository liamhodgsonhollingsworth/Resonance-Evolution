---
id: dropdown_radial_v1
kind: renderer
name: dropdown_radial_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: DropdownNode
text: Radial raster dropdown — options arranged around a circle, with the selected option highlighted. Per N-F027's per-module-plan spec the "radial = a circular menu" variant; functional state identical to minimal/chunky.
---

```json
{
  "name": "dropdown_radial_v1",
  "description": "Radial dropdown: options around a circle, selected highlighted.",
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
    "path": "renderers/presentations/dropdown_radial_v1.py",
    "callable": "render"
  }
}
```

# dropdown_radial_v1

The radial variant — options arranged at equal angles around a center, with the selected option drawn as a larger dot. Closes the per-module-plan's "radial" mention with a working raster. Use sparingly; the open-form chunky variant is more legible for most lists.
