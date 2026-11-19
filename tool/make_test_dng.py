#!/usr/bin/env python3
"""Write a small synthetic linear DNG for encoder tests.

usage: make_test_dng.py OUT.dng WIDTH HEIGHT ORIENTATION

16-bit LinearRaw RGB gradient, Make "TestCam", Model "Synth DNG",
DateTime 2025:06:01 10:00:00. No dependencies beyond the standard library.
"""
import math
import struct
import sys


def pixels(w, h):
    rows = []
    for y in range(h):
        row = bytearray()
        for x in range(w):
            r = int(65535 * x / w)
            g = int(65535 * y / h)
            b = int(65535 * (0.5 + 0.5 * math.sin(x / 40) * math.cos(y / 40)))
            row += struct.pack('<HHH', r, g, b)
        rows.append(bytes(row))
    return b''.join(rows)


def main():
    out, w, h, orientation = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    data = pixels(w, h)
    entries = []

    def add(tag, typ, vals):
        if typ == 2:
            b = vals.encode() + b'\0'
            cnt = len(b)
        elif typ == 1:
            b = bytes(vals); cnt = len(vals)
        elif typ == 3:
            b = b''.join(struct.pack('<H', v) for v in vals); cnt = len(vals)
        elif typ == 4:
            b = b''.join(struct.pack('<I', v) for v in vals); cnt = len(vals)
        elif typ == 5:
            b = b''.join(struct.pack('<II', *v) for v in vals); cnt = len(vals)
        elif typ == 10:
            b = b''.join(struct.pack('<ii', *v) for v in vals); cnt = len(vals)
        entries.append((tag, typ, cnt, b))

    xyz_to_srgb = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
    add(254, 4, [0]); add(256, 4, [w]); add(257, 4, [h]); add(258, 3, [16, 16, 16])
    add(259, 3, [1]); add(262, 3, [34892])
    add(271, 2, 'TestCam'); add(272, 2, 'Synth DNG')
    add(273, 4, [0]); add(274, 3, [orientation]); add(277, 3, [3]); add(278, 4, [h])
    add(279, 4, [len(data)]); add(284, 3, [1]); add(306, 2, '2025:06:01 10:00:00')
    add(50706, 1, [1, 4, 0, 0]); add(50708, 2, 'TestCam Synth')
    add(50721, 10, [(int(v * 10000), 10000) for v in xyz_to_srgb])
    add(50728, 5, [(1, 1)] * 3); add(50778, 3, [21])
    entries.sort()

    n = len(entries)
    ifd_off = 8
    extra_off = ifd_off + 2 + 12 * n + 4
    extra = bytearray()
    fixed = []
    for tag, typ, cnt, b in entries:
        if len(b) <= 4:
            fixed.append((tag, typ, cnt, b.ljust(4, b'\0')))
        else:
            off = extra_off + len(extra)
            extra += b
            if len(extra) % 2:
                extra += b'\0'
            fixed.append((tag, typ, cnt, struct.pack('<I', off)))
    data_off = extra_off + len(extra)

    buf = bytearray(b'II*\0' + struct.pack('<I', ifd_off) + struct.pack('<H', n))
    for tag, typ, cnt, v in fixed:
        if tag == 273:
            v = struct.pack('<I', data_off)
        buf += struct.pack('<HHI', tag, typ, cnt) + v
    buf += struct.pack('<I', 0) + extra + data
    with open(out, 'wb') as f:
        f.write(buf)


if __name__ == '__main__':
    main()
