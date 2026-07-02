class_name TextureSynth
extends RefCounted
## The Godot DELEGATE that turns a renderer-NEUTRAL procedural-texture descriptor (plain
## Dictionary DATA) into a live ImageTexture. Part of the live-texturing module (Liam
## 2026-07-02: untextured building blocks "textured LIVE using in-engine tools", driven
## by the node system): the TextureApply primitive emits `material` descriptors as data;
## THIS file is where that data becomes Godot pixels. Renderers are dumb delegates — the
## descriptor carries everything, so the same data can later drive a three.js delegate.
##
## Descriptor shape (all keys optional beyond `kind`):
##   { "kind": "checker",  "size": 64, "colors": [[r,g,b],[r,g,b]], "cells": 8 }
##   { "kind": "gradient", "size": 64, "colors": [[r,g,b],[r,g,b]], "axis": "x"|"y" }
##   { "kind": "noise",    "size": 64, "colors": [[r,g,b],[r,g,b]], "seed": 1337 }
##   { "kind": "bricks",   "size": 64, "colors": [[brick],[mortar]], "rows": 4, "cols": 4, "mortar": 0.08 }
##
## DETERMINISTIC: the same descriptor always yields the same pixels (noise is seeded), so
## textures are content-addressed by their data — hotload can compare, tests can hash.

const DEFAULT_SIZE := 64
const DEFAULT_COLORS := [[0.85, 0.85, 0.88], [0.35, 0.38, 0.45]]


## Descriptor -> ImageTexture. Unknown/malformed kinds return a flat fill of the first
## colour (never null, never crashes — a bad descriptor still yields a visible texture).
static func synthesize(desc: Dictionary) -> ImageTexture:
	return ImageTexture.create_from_image(synthesize_image(desc))


## The pure pixel step (separated so tests can hash bytes without GPU resources).
static func synthesize_image(desc: Dictionary) -> Image:
	var size := int(desc.get("size", DEFAULT_SIZE))
	size = clampi(size, 2, 1024)
	var colors := _colors(desc)
	var a: Color = colors[0]
	var b: Color = colors[1]
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	match String(desc.get("kind", "")):
		"checker":
			var cells := maxi(1, int(desc.get("cells", 8)))
			var cw := float(size) / float(cells)
			for y in size:
				for x in size:
					var on := (int(x / cw) + int(y / cw)) % 2 == 0
					img.set_pixel(x, y, a if on else b)
		"gradient":
			var horizontal := String(desc.get("axis", "y")) == "x"
			for y in size:
				for x in size:
					var t := (float(x) if horizontal else float(y)) / float(size - 1)
					img.set_pixel(x, y, a.lerp(b, t))
		"noise":
			var rng := RandomNumberGenerator.new()
			rng.seed = int(desc.get("seed", 1337))
			for y in size:
				for x in size:
					img.set_pixel(x, y, a.lerp(b, rng.randf()))
		"bricks":
			var rows := maxi(1, int(desc.get("rows", 4)))
			var cols := maxi(1, int(desc.get("cols", 4)))
			var mortar := clampf(float(desc.get("mortar", 0.08)), 0.0, 0.45)
			var rh := float(size) / float(rows)
			var cw2 := float(size) / float(cols)
			for y in size:
				var row := int(y / rh)
				var ry := fmod(float(y), rh) / rh
				for x in size:
					# odd rows offset by half a brick (running bond)
					var fx := float(x) + (cw2 * 0.5 if row % 2 == 1 else 0.0)
					var rx := fmod(fx, cw2) / cw2
					var is_mortar := ry < mortar or ry > 1.0 - mortar or rx < mortar or rx > 1.0 - mortar
					img.set_pixel(x, y, b if is_mortar else a)
		_:
			img.fill(a)
	return img


## Stable content hash of the pixels a descriptor produces (tests + change detection).
static func content_hash(desc: Dictionary) -> String:
	return synthesize_image(desc).get_data().hex_encode().md5_text()


static func _colors(desc: Dictionary) -> Array:
	var raw = desc.get("colors", DEFAULT_COLORS)
	var out := [Color(DEFAULT_COLORS[0][0], DEFAULT_COLORS[0][1], DEFAULT_COLORS[0][2]),
				Color(DEFAULT_COLORS[1][0], DEFAULT_COLORS[1][1], DEFAULT_COLORS[1][2])]
	if typeof(raw) == TYPE_ARRAY:
		for i in mini(2, raw.size()):
			var c = raw[i]
			if typeof(c) == TYPE_ARRAY and c.size() >= 3:
				out[i] = Color(float(c[0]), float(c[1]), float(c[2]))
	return out
