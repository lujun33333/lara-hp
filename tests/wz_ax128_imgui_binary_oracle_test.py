"""AX Pro 1.2.8 Dear ImGui renderer oracle, pinned to the reference Mach-O."""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path


EXPECTED_SHA256 = "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
IMAGE_BASE = 0x100000000
BINARY = Path(__file__).resolve().parents[3] / ".ax128" / "axpro.bin"


def file_offset(va: int) -> int:
    return va - IMAGE_BASE


def instruction(va: int) -> bytes:
    return image[file_offset(va) : file_offset(va) + 4]


def relative_imp(entry: int) -> int:
    relative = struct.unpack_from("<i", image, file_offset(entry + 8))[0]
    return entry + 8 + relative


def chained_cstring(pointer_va: int) -> str:
    encoded = struct.unpack_from("<Q", image, file_offset(pointer_va))[0]
    target = IMAGE_BASE + (encoded & 0xFFFFFFFF)
    start = file_offset(target)
    end = image.index(b"\0", start)
    return image[start:end].decode("utf-8")


if not BINARY.is_file():
    raise AssertionError(f"AX 1.2.8 oracle binary is missing: {BINARY}")
image = BINARY.read_bytes()
actual_sha256 = hashlib.sha256(image).hexdigest()
assert actual_sha256 == EXPECTED_SHA256, (
    f"AX binary changed: expected {EXPECTED_SHA256}, got {actual_sha256}"
)

# The in-place string decoder at 0x100692224 writes this version to
# 0x100e8fc0b immediately before DebugCheckVersionAndDataLayout.
u8 = lambda va: image[file_offset(va)]
source0 = [u8(0x100E8FC00 + i) for i in range(4)]
source1 = [u8(0x100E8FC04 + i) for i in range(4)]
source2 = [u8(0x100E8FC08 + i) for i in range(3)]
decoded = bytes(
    [
        source0[0] ^ 0x52,
        source0[1] ^ 0x71,
        (source0[2] - 2 * (source0[2] & 0x17) + 0x17) & 0xFF,
        (source0[3] - 2 * (source0[3] & 0x99) + 0x19) & 0xFF,
        (source1[0] - 2 * (source1[0] & 0x44) + 0x44) & 0xFF,
        source1[1] ^ 0xA1,
        ((0x6C & ~source1[2]) | (source1[2] & 0x93)) ^ 0xDE,
        source1[3] ^ 0xE8,
        source2[0] ^ 0xF6,
        source2[1] ^ 0x6F,
        source2[2] ^ 0xC1,
    ]
)
assert decoded == b"1.92.5 WIP\0"

# DebugCheckVersionAndDataLayout compares the caller's structure sizes against
# these exact constants: IO, Style, Vec2, Vec4, DrawVert and DrawIdx.
layout_cmp = {
    0x100692354: "1f632ff1",  # cmp x24,#0xbd8
    0x100692370: "ffb213f1",  # cmp x23,#0x4ec
    0x10069238C: "df2200f1",  # cmp x22,#8
    0x1006923A8: "bf4200f1",  # cmp x21,#0x10
    0x1006923C4: "9f5200f1",  # cmp x20,#0x14
    0x1006923E0: "7f0a00f1",  # cmp x19,#2
}
for address, expected_hex in layout_cmp.items():
    assert instruction(address) == bytes.fromhex(expected_hex)
assert image[file_offset(0x100C82208) : file_offset(0x100C82208) + 4] == struct.pack(
    "<f", 0.01666666753590107
)

# initWithFrame loads the bundled OTF at 18 px and supplies the default range.
assert instruction(0x10077B138) == bytes.fromhex("0050261e")  # fmov s0,#18.0
assert instruction(0x10077B0D4) == bytes.fromhex("6f20f697")  # glyph-range helper
assert instruction(0x10077B148) == bytes.fromhex("4d08f697")  # AddFontFromFileTTF
raw_u16 = lambda va: struct.unpack_from("<H", image, file_offset(va))[0]
assert raw_u16(0x100E00A08) ^ 0x8B95 == 0x20
assert raw_u16(0x100E00A0A) ^ 0x539E == 0xFF
range_end = raw_u16(0x100E00A0C)
range_end = (((-0x54B5) & 0xFFFF) & (~range_end & 0xFFFF) | (range_end & 0x54B4)) ^ 0x1AAA
assert range_end == 0

# ObjC relative method list fixes the three foreground producer/submission IMPs.
method_imps = {
    0x100C80504: 0x1007864D4,  # drawInMTKView:
    0x100C8051C: 0x100788BF8,  # bnd4sfh5
    0x100C80528: 0x100793890,  # bg6dw1sf
}
for entry, expected_imp in method_imps.items():
    assert relative_imp(entry) == expected_imp
    assert instruction(expected_imp) == bytes.fromhex("7f2303d5")  # pacibsp

# bg6's seven backend-neutral primitive consumers, in binary order:
# Rect, Line, Image, Circle(outline/fill), Circle(second site), Text and Arc.
primitive_consumer_sites = {
    0x1007BEC24: "295543f9",
    0x1007BFC90: "085943f9",
    0x1007C0AE8: "015d43f9",
    0x1007C1C34: "016143f9",
    0x1007C3474: "086143f9",
    0x1007C44E8: "017543f9",
    0x1007C61B4: "017943f9",
}
for address, expected_hex in primitive_consumer_sites.items():
    assert instruction(address) == bytes.fromhex(expected_hex)
assert [
    chained_cstring(va)
    for va in (0x100CB16A8, 0x100CB16B0, 0x100CB16B8, 0x100CB16C0, 0x100CB16E8, 0x100CB16F0)
] == [
    "addRect:color:rounding:flags:thickness:",
    "addLineFrom:to:color:thickness:",
    "addImage:frame:color:rounding:",
    "addCircleAt:radius:color:filled:thickness:",
    "addText:position:fontSize:color:",
    "addArcAt:radius:startAngle:endAngle:color:thickness:",
]

print("PASS: AX 1.2.8 ImGui version, ABI layout and renderer IMP oracle")
