"""AX 1.2.8 application-lifecycle and background-render binary oracle."""

from __future__ import annotations

import hashlib
import os
import struct
from pathlib import Path


EXPECTED_SHA256 = (
    "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
)
IMAGE_BASE = 0x100000000


def find_binary() -> Path:
    candidates = []
    if os.environ.get("AX128_BINARY"):
        candidates.append(Path(os.environ["AX128_BINARY"]))
    candidates.extend(
        [
            Path(__file__).resolve().parents[3] / ".ax128" / "axpro.bin",
            Path(os.environ.get("LOCALAPPDATA", "")) / "Temp" / "axpro" / "axpro.bin",
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise AssertionError("AX 1.2.8 axpro.bin oracle not found")


image = find_binary().read_bytes()
assert hashlib.sha256(image).hexdigest() == EXPECTED_SHA256


def offset(address: int) -> int:
    result = address - IMAGE_BASE
    assert 0 <= result < len(image)
    return result


def instruction(address: int) -> int:
    return struct.unpack_from("<I", image, offset(address))[0]


def qword(address: int) -> int:
    return struct.unpack_from("<Q", image, offset(address))[0]


def assert_bytes(address: int, expected_hex: str) -> None:
    expected = bytes.fromhex(expected_hex)
    assert image[offset(address) : offset(address) + len(expected)] == expected


def chained_cstring(pointer_address: int) -> str:
    target = IMAGE_BASE + (qword(pointer_address) & 0x7FFFFFFFFFF)
    start = offset(target)
    end = image.index(b"\0", start)
    return image[start:end].decode("utf-8")


def relative_imp(entry: int) -> int:
    relative = struct.unpack_from("<i", image, offset(entry + 8))[0]
    return entry + 8 + relative


def branch_target(address: int) -> int | None:
    opcode = instruction(address)
    if opcode & 0xFC000000 != 0x94000000:
        return None
    immediate = opcode & 0x03FFFFFF
    if immediate & 0x02000000:
        immediate -= 0x04000000
    return address + immediate * 4


# gdr2sae1a's relative method list binds the two lifecycle selectors and the
# dedicated background tick to their recovered IMPs.
assert instruction(0x100C804C0) == 0x8000000C
assert instruction(0x100C804C4) == 57
assert chained_cstring(0x100CB1548) == "applicationDidEnterBackgroundForOrientation:"
assert chained_cstring(0x100CB1550) == "applicationDidBecomeActiveForRendering:"
assert relative_imp(0x100C80588) == 0x1007E2548
assert relative_imp(0x100C80594) == 0x1007E29E8
assert relative_imp(0x100C80510) == 0x100786F3C

# initWithFrame:@0x100774430 registers both selectors with
# NSNotificationCenter. The consecutive chained imports 0x178/0x179 match the
# adjacent UIApplication active/background notification symbol strings.
assert image[offset(0x100FFE674) : offset(0x100FFE674) + 40] == (
    b"UIApplicationDidBecomeActiveNotification"
)
assert image[offset(0x100FFE69E) : offset(0x100FFE69E) + 43] == (
    b"UIApplicationDidEnterBackgroundNotification"
)
assert qword(0x100CA4BE8) & 0xFFFF == 0x178
assert qword(0x100CA4BF0) & 0xFFFF == 0x179
assert_bytes(0x10077A580, "03a542f9")  # background selector -> x3
assert_bytes(0x10077A588, "08f945f9040140f9")  # background notification -> x4
assert branch_target(0x10077A5A8) == 0x100C7E82C  # objc_msgSend
assert_bytes(0x10077F710, "03a942f9")  # active selector -> x3
assert_bytes(0x10077F718, "08f545f9040140f9")  # active notification -> x4

# applicationDidEnterBackgroundForOrientation: reads mtkView, pauses it, then
# calls configureHostedBackgroundLayerHierarchy. The active IMP performs the
# inverse setPaused:NO transition.
assert chained_cstring(0x100CB1458) == "mtkView"
assert chained_cstring(0x100CB14C8) == "setPaused:"
assert chained_cstring(0x100CB1560) == "configureHostedBackgroundLayerHierarchy"
assert_bytes(0x1007E27BC, "012d42f9")
assert_bytes(0x1007E27D4, "016542f9")
assert_bytes(0x1007E27DC, "22008052")  # w2 = true
assert_bytes(0x1007E27F0, "14b142f9")
assert_bytes(0x1007E2A20, "352d42f9")
assert_bytes(0x1007E2CE4, "016542f9")
assert_bytes(0x1007E2CEC, "02008052")  # w2 = false

# The background tick consults UIApplication state/MTK pause state and retains
# an independent backgroundLayerRenderer consumer rather than deleting Metal.
assert chained_cstring(0x100CB0058) == "sharedApplication"
assert chained_cstring(0x100CB1588) == "applicationState"
assert chained_cstring(0x100CB1590) == "isPaused"
assert chained_cstring(0x100CB1470) == "backgroundLayerRenderer"
assert_bytes(0x100787930, "212f40f9")
assert_bytes(0x100788044, "01c542f9")
assert_bytes(0x100788318, "01c942f9")
assert_bytes(0x100788968, "013942f9")

print("PASS: AX 1.2.8 UIApplication lifecycle and CA/Metal backend oracle")
