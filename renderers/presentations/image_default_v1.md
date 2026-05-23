---
id: image_default_v1
kind: renderer
name: image_default_v1
author: Alethea
created: 2026-05-22
executable: null
body-format: renderer-spec
presentation-of: ImageNode
text: Default raster variant of the ImageNode primitive (N-F026). Resolves src via PIL, scales to requested dimensions honoring preserve_aspect, falls back to the placeholder color when src is missing/unreadable. The headless-test default for ImageNode per Decision A1 of brief 03's per-module plan.
---

```json
{
  "name": "image_default_v1",
  "description": "Default raster image variant: PIL-resolves src; honors preserve_aspect; placeholder color fills missing-source regions.",
  "input": {
    "schema": {
      "type": "object",
      "properties": {
        "primitive_state": {
          "type": "object",
          "properties": {
            "src": {"type": "string"},
            "alt_text": {"type": "string"},
            "preserve_aspect": {"type": "boolean"},
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
    "path": "renderers/presentations/image_default_v1.py",
    "callable": "render"
  }
}
```

# image_default_v1

The default raster variant of ImageNode. Resolves the ``src`` via PIL, scales to the requested dimensions honoring ``preserve_aspect``, falls back to the configured ``placeholder_color`` when the source is missing or unreadable. Composes against ``node_types/image.py``'s resolution helper to keep the missing-source behavior identical between the primitive's default emit and this variant.

Per SPEC-090's 1:N functional/visual binding: this is one of N possible visual variants for ImageNode. Brief 14 (aesthetic-nodes) will ship painterly + lit variants per Cross-cut X4 of the per-module plan; they bind through the same ``displayed_by`` slot without touching the functional primitive.
