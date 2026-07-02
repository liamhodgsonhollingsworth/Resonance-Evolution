#!/usr/bin/env python3
"""Independent stereogram decoder oracle (second implementation, zero shared code with the
GDScript generator/decoder). Measures the repeat period of a stereogram row window by exact
pixel self-match and compares it to the expected period from the viewing-geometry model.

Usage:
    py decode_stereogram.py <png> <row>:<x0>:<expected_period> [<row>:<x0>:<expected> ...]

For each spec, scans offsets o in [4, 110] over columns [x0, width) of the row and reports the
smallest o with >= 99.5% exact matches. Exit 0 iff every spec decodes to its expected period.
See notes/design/stereogram_vr_viewer_2026-07-02.md (the SIRDS constraint img[x] == img[x-s]).
"""
import sys

from PIL import Image


def first_period(px, width: int, row: int, x0: int, scan_max: int = 110) -> int:
    for o in range(4, scan_max + 1):
        same = sum(1 for x in range(x0, width) if px[x, row] == px[x - o, row])
        if same / max(1, width - x0) >= 0.995:
            return o
    return -1


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    img = Image.open(argv[1]).convert("RGB")
    px = img.load()
    ok = True
    for spec in argv[2:]:
        row, x0, expected = (int(p) for p in spec.split(":"))
        got = first_period(px, img.width, row, x0)
        line_ok = got == expected
        ok = ok and line_ok
        print(f"{'PASS' if line_ok else 'FAIL'} row {row} x0 {x0}: expected period {expected}, decoded {got}")
    print("RESULT:", "ALL PASS" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
