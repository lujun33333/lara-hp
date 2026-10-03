"""Pin XPF start/stop failure ownership to the AX Pro 1.2.8 binary."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path


EXPECTED_SHA256 = (
    "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
)
IMAGE_BASE = 0x100000000
START = 0x100A8BA7C
START_END = 0x100A8C390
STOP = 0x100A8C830


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


def instruction(address: int) -> int:
    offset = address - IMAGE_BASE
    assert 0 <= offset <= len(image) - 4
    return int.from_bytes(image[offset : offset + 4], "little")


def assert_bytes(address: int, expected_hex: str) -> None:
    expected = bytes.fromhex(expected_hex)
    offset = address - IMAGE_BASE
    assert image[offset : offset + len(expected)] == expected


def branch_target(address: int, opcode: int) -> int | None:
    if opcode & 0xFC000000 != 0x94000000:
        return None
    immediate = opcode & 0x03FFFFFF
    if immediate & 0x02000000:
        immediate -= 0x04000000
    return address + immediate * 4


# open -> fd store -> signed failure branch.  fstat is deliberately unchecked:
# control flows straight through its result load and into mmap.
assert_bytes(0x100A8BAA8, "adcb0794")
assert_bytes(0x100A8BAB0, "00f90cb9")
assert_bytes(0x100A8BAB4, "802ef837")
assert_bytes(0x100A8BABC, "7cca0794")
assert_bytes(0x100A8BAC0, "e13f40f9")
assert_bytes(0x100A8BACC, "610a00f9")
assert_bytes(0x100A8BAE4, "faca0794")

# mmap stores MAP_FAILED in gXPF before branching.  A failed decompression has
# no direct branch; its null stream reaches the common Fat constructor failure.
assert_bytes(0x100A8BAE8, "600600f9")
assert_bytes(0x100A8BAF0, "002d0054")
assert_bytes(0x100A8BB28, "a9f4ff97")
assert_bytes(0x100A8BB2C, "800600f9")
assert_bytes(0x100A8BB30, "a00000b4")
assert_bytes(0x100A8BB44, "6ea2ff97")
assert_bytes(0x100A8BB48, "a02a00b4")

# The Fat candidate remains local through all three ARM64 slice attempts and is
# written into gXPF only after one succeeds.  Consequently stop cannot free the
# local candidate on the all-slices-failed AX path.
assert_bytes(0x100A8BB64, "f9a1ff97")
assert_bytes(0x100A8BB84, "f1a1ff97")
assert_bytes(0x100A8BBA0, "eaa1ff97")
assert_bytes(0x100A8BBA4, "c02700b4")
assert_bytes(0x100A8BBB0, "930200a9")

# Section-derived base, entry, and version are the remaining explicit start
# failures.  Item registration has no checked failure edge in AX.
assert_bytes(0x100A8C1E0, "a07e04a9")
assert_bytes(0x100A8C1FC, "200a0054")
assert_bytes(0x100A8C208, "280a00b4")
assert_bytes(0x100A8C298, "000600b4")
assert_bytes(0x100A8C328, "b9f7ff97d4f3ff978ad8ff97e2d4ff97")
assert_bytes(0x100A8C338, "00008052")

# start never calls stop itself: partial-state ownership belongs to callers.
for address in range(START, START_END, 4):
    assert branch_target(address, instruction(address)) != STOP

# xpf_set_error replaces/frees the old error, while stop intentionally leaves
# that separate global untouched so callers can log after cleanup.
assert_bytes(0x100A8C3C8, "60ae44f9")
assert_bytes(0x100A8C3CC, "400000b4")
assert_bytes(0x100A8C3D0, "2fc80794")
assert_bytes(0x100A8C3D8, "68ae04f9")

# Dictionary base-set failure returns null without releasing the just-created
# dictionary.  Later set failures go through the release call at 0x100a8c808.
assert_bytes(0x100A8C768, "20050035")
assert_bytes(0x100A8C804, "e00313aa")
assert_bytes(0x100A8C808, "5dc90794")
assert_bytes(0x100A8C80C, "130080d2")

# stop ordering: map, decompressed buffer, fd, AX-owned section subset,
# container, six strings, item list, then the full 0x120-byte state reset.
assert_bytes(0x100A8C844, "008146f9")
assert_bytes(0x100A8C854, "a2c70794")
assert_bytes(0x100A8C85C, "008946f9")
assert_bytes(0x100A8C864, "0ac70794")
assert_bytes(0x100A8C86C, "00f94cb9")
assert_bytes(0x100A8C874, "6ac60794")
for address in (
    0x100A8C884,
    0x100A8C894,
    0x100A8C8A4,
    0x100A8C8B4,
    0x100A8C8C4,
    0x100A8C8D4,
    0x100A8C8E4,
    0x100A8C8F4,
    0x100A8C904,
    0x100A8C914,
    0x100A8C924,
    0x100A8C934,
    0x100A8C944,
    0x100A8C954,
    0x100A8C964,
):
    assert branch_target(address, instruction(address)) == 0x100A7893C
assert branch_target(0x100A8C974, instruction(0x100A8C974)) == 0x100A74414
for address in (
    0x100A8C984,
    0x100A8C994,
    0x100A8C9A4,
    0x100A8C9B4,
    0x100A8C9C4,
    0x100A8C9D4,
    0x100A8C9E8,
):
    assert branch_target(address, instruction(address)) == 0x100C7E48C
assert_bytes(0x100A8C9FC, "1f8900f9")
assert_bytes(
    0x100A8CA00,
    "00e4006f008107ad008106ad008105ad008104ad008103ad008102ad008101ad"
    "008100ad0001803d",
)

print("AX 1.2.8 XPF lifecycle oracle: PASS")
