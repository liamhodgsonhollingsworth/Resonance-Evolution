"""Presentation-variant renderer-nodes for brief 03's control primitives.

Each variant is a substrate-style ``kind: renderer`` node — a paired
``.md`` (renderer-spec manifest) + ``.py`` (callable) at this directory.
Variants declare ``presentation-of: <PrimitiveKind>`` in their manifest
+ implement ``render(input)`` taking ``{primitive_state, context}``
and returning a raster numpy array.

Per Decision A1 of the per-module plan:

  - The functional primitive (ScrollBarNode, SliderNode, DropdownNode)
    owns the function — state schema, verbs, default emit.
  - Each visual variant owns one specific look — the same primitive_state
    in, a differently-styled raster out.
  - Swapping variants (via the primitive's ``displayed_by:`` field)
    changes the look without changing the function — Scenario 2 from
    the per-module plan.

Brief 03 commit 3 ships 9 raster variants:
  - scroll_bar: minimal, chunky, thin
  - slider:     minimal, chunky, knob
  - dropdown:   minimal, chunky, radial

The HTML side ships at Resonance-Website/renderers/presentations/ with
the same naming.
"""
