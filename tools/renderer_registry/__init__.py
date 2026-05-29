"""Renderer-kind registry + drag-drop dispatcher runtime.

Wave 2 of the MVP plan. See:
    renderer_registry.weft       — canonical Weft specification (registry)
    registry.py                  — Python runtime (registry)
    drag_drop_dispatcher.py      — Python runtime (dispatcher, wired through registry)
    tests/                       — adversarial test set covering both
"""

from tools.renderer_registry.registry import (
    RendererBinding,
    RendererRegistry,
    ValidationError,
    VIRTUAL_KIND_DECLARATIONS,
    get_registry,
    reset_registry,
)

__all__ = [
    "RendererBinding",
    "RendererRegistry",
    "ValidationError",
    "VIRTUAL_KIND_DECLARATIONS",
    "get_registry",
    "reset_registry",
]
