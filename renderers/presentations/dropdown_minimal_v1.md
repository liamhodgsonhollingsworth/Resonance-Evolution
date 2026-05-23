---
id: dropdown_minimal_v1
kind: renderer
name: dropdown_minimal_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: DropdownNode
text: Minimal raster dropdown — closed-form rectangle with selected label and small downward chevron. The headless-test default.
---

```json
{
  "name": "dropdown_minimal_v1",
  "description": "Minimal dropdown: closed-form rectangle with selected label + chevron.",
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
    "path": "renderers/presentations/dropdown_minimal_v1.py",
    "callable": "render"
  }
}
```

# dropdown_minimal_v1

The minimal-style variant — closed-form rectangle showing the selected label with a downward chevron on the right.
