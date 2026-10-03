"""AX Pro 1.2.8 pending-touch oracle, pinned to one Mach-O and VA set."""

from __future__ import annotations

import hashlib
import struct
from pathlib import Path


EXPECTED_SHA256 = "cc947605b97b90d898e784bf73dcab120c44c9281299fe840285dd67dfec1fb4"
IMAGE_BASE = 0x100000000
BINARY = Path(__file__).resolve().parents[3] / ".ax128" / "axpro.bin"


def file_offset(va: int) -> int:
    # This pinned thin Mach-O maps its image ranges at file offset VA-imagebase.
    return va - IMAGE_BASE


def instruction(va: int) -> bytes:
    return image[file_offset(va) : file_offset(va) + 4]


def relative_imp(entry: int) -> int:
    relative = struct.unpack_from("<i", image, file_offset(entry + 8))[0]
    return entry + 8 + relative


def relative_cstring(field: int) -> str:
    relative = struct.unpack_from("<i", image, file_offset(field))[0]
    start = file_offset(field + relative)
    end = image.index(b"\0", start)
    return image[start:end].decode("utf-8")


def chained_cstring(pointer_va: int) -> str:
    encoded = struct.unpack_from("<Q", image, file_offset(pointer_va))[0]
    target = IMAGE_BASE + (encoded & 0x7FFFFFFFFFF)
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

# The complete kif8h31uie class-method surface is two no-argument lifecycle
# methods plus five touch entry points. There is no physical-Cancel selector.
assert struct.unpack_from("<II", image, file_offset(0x100C7F740)) == (
    0x8000000C,
    7,
)
owner_methods = (
    (0x100C7F748, "fk3n8qx2vt", "v16@0:8", 0x10082D1D8),
    (0x100C7F754, "zt6m3qx8vk", "v16@0:8", 0x100834D78),
    (0x100C7F760, "jn4b8xq3mv:pkid98ejqq:",
     "v40@0:8{CGPoint=dd}16q32", 0x100839DD8),
    (0x100C7F76C, "vt6x2bq9nk:pkid98ejqq:",
     "v40@0:8{CGPoint=dd}16q32", 0x100842D98),
    (0x100C7F778, "qm3n7xb5vj:pkid98ejqq:",
     "v40@0:8{CGPoint=dd}16q32", 0x1008435C0),
    (0x100C7F784, "bx8v4nq2tj:", "v32@0:8{CGPoint=dd}16", 0x100844518),
    (0x100C7F790, "nk5q9bx3mv:to:steps:",
     "v56@0:8{CGPoint=dd}16{CGPoint=dd}32q48", 0x100849DB0),
)
for entry, expected_selector, expected_types, expected_imp in owner_methods:
    selector_slot = entry + struct.unpack_from(
        "<i", image, file_offset(entry)
    )[0]
    assert chained_cstring(selector_slot) == expected_selector
    assert relative_cstring(entry + 4) == expected_types
    assert relative_imp(entry) == expected_imp

# ObjC method-list entries bind the public touch entry points used by the
# behavior replay: down=kind0, move=kind1, up=kind2, point/timed=kind3.
touch_entry_imps = {
    0x100C7F760: 0x100839DD8,
    0x100C7F76C: 0x100842D98,
    0x100C7F778: 0x1008435C0,
    0x100C7F784: 0x100844518,
    0x100C7F790: 0x100849DB0,
}
for entry, expected_imp in touch_entry_imps.items():
    assert relative_imp(entry) == expected_imp

# Each entry point materializes its kind immediately before the shared helper.
# No fifth kind is present for Cancel.
assert instruction(0x10083A508) == bytes.fromhex("01008052")  # mov w1,#0
assert instruction(0x10083A50C) == bytes.fromhex("aa000094")
assert instruction(0x100843190) == bytes.fromhex("21008052")  # mov w1,#1
assert instruction(0x100843194) == bytes.fromhex("88ddff97")
assert instruction(0x100843860) == bytes.fromhex("41008052")  # mov w1,#2
assert instruction(0x100843868) == bytes.fromhex("d3dbff97")
assert instruction(0x100847BDC) == bytes.fromhex("61008052")  # mov w1,#3
assert instruction(0x100847BE4) == bytes.fromhex("f4caff97")

# STPendingTouchAction's four fields and all getter/setter IMPs.
assert struct.unpack_from("<4I", image, file_offset(0x100CB22E0)) == (
    0x08,
    0x10,
    0x18,
    0x20,
)
accessor_imps = {
    0x100C80388: 0x100829358,  # actionBlock
    0x100C80394: 0x100829474,  # setActionBlock:
    0x100C803A0: 0x1008297A8,  # kind
    0x100C803AC: 0x10082A068,  # setKind:
    0x100C803B8: 0x10082A66C,  # pointerID
    0x100C803C4: 0x10082AC18,  # setPointerID:
    0x100C803D0: 0x10082B010,  # expirationTime
    0x100C803DC: 0x10082B6A8,  # setExpirationTime:
}
for entry, expected_imp in accessor_imps.items():
    assert relative_imp(entry) == expected_imp

# The two no-argument owner lifecycle methods clear the pending arrays. This
# is teardown/start cleanup, not a Cancel action and not an action ivar.
assert instruction(0x100833718) == bytes.fromhex("1f831f39")
assert instruction(0x100833720) == bytes.fromhex("00e943f9")
assert instruction(0x100833728) == bytes.fromhex("015940f9")
assert instruction(0x10083372C) == bytes.fromhex("402c1194")
assert instruction(0x100833730) == bytes.fromhex("fffe9fc8")
assert instruction(0x100836570) == bytes.fromhex("345940f9")
assert instruction(0x10083657C) == bytes.fromhex("ac201194")
assert instruction(0x100836584) == bytes.fromhex("bfea03f9")
assert instruction(0x100836590) == bytes.fromhex("a0ee43f9")
assert instruction(0x100836598) == bytes.fromhex("a5201194")
assert instruction(0x1008365A0) == bytes.fromhex("bfee03f9")

# TTL source: CFAbsoluteTimeGetCurrent's d0 receives an immediate 0.75 add.
assert instruction(0x10087BC74) == bytes.fromhex("ea061094")  # CFAbsoluteTimeGetCurrent
assert instruction(0x10087B06C) == bytes.fromhex("01106d1e")  # fmov d1,#0.75
assert instruction(0x10087B070) == bytes.fromhex("0028611e")  # fadd d0,d0,d1

# Strict expiration boundary in the enumeration block: expirationTime > now
# is live.  On an expired normal lifecycle it sets both the captured stale flag
# and NSArray enumeration stop flag before the caller's removeAllObjects.
assert instruction(0x10085B330) == bytes.fromhex("0020611e")  # fcmp d0,d1
assert instruction(0x10085B334) == bytes.fromhex("e8d79f1a")  # cset w8,gt
assert instruction(0x10085B1F0) == bytes.fromhex("a81a40f9")  # ldr x8,[x21,#0x30]
assert instruction(0x10085B1F8) == bytes.fromhex("09010039")  # strb w9,[x8]
assert instruction(0x10085B1FC) == bytes.fromhex("c9020039")  # strb w9,[x22]
assert chained_cstring(0x100CB10B0) == "removeAllObjects"
assert instruction(0x10085AAE8) == bytes.fromhex("015940f9")  # selector load
assert instruction(0x10085AB90) == bytes.fromhex("278f1094")  # removeAllObjects

# Expired kind 3 instead contributes only its index to the removal index set.
assert chained_cstring(0x100CB1158) == "removeObjectsAtIndexes:"
assert instruction(0x100859F78) == bytes.fromhex("01ad40f9")  # selector load
assert instruction(0x10085B488) == bytes.fromhex("01c143f9")  # addIndex: selref
assert instruction(0x10085B48C) == bytes.fromhex("e20314aa")  # index argument
assert instruction(0x10085B490) == bytes.fromhex("e78c1094")  # objc_msgSend

# Move coalescing is tail-only: index=count-1, then the recovered replace path
# stores the new action at that same indexed subscript.
assert instruction(0x1008784BC) == bytes.fromhex("602200f9")  # save count
assert instruction(0x1008784C0) == bytes.fromhex("020400d1")  # sub x2,x0,#1
assert chained_cstring(0x100CB1340) == "setObject:atIndexedSubscript:"
assert instruction(0x10087BEB4) == bytes.fromhex("01a141f9")  # selector load
assert instruction(0x10087BF78) == bytes.fromhex("e20316aa")  # new action
assert instruction(0x10087BF7C) == bytes.fromhex("632640f9")  # saved tail index
assert instruction(0x10087BF80) == bytes.fromhex("2b0a1094")  # replace message

print("PASS: AX 1.2.8 pending-touch SHA, complete method surface, cleanup, TTL, expiry and tail-merge oracle")
