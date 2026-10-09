"""Hash-bound, read-only evidence for Core 1.7 aim-display geometry."""

from hashlib import sha256
from pathlib import Path
import struct
import zipfile

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs


ROOT = Path(__file__).resolve().parents[1]
CORE_IPA = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"
CORE_SHA256 = "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
BASE = 0x100000000

SITES = {
    # c4af8 predicted world point and its identity-bound 0x28 publication
    0x1000C4DFC: ("stp", "[x19, #0x38]"),
    0x1000C4E04: ("str", "[x19, #0x40]"),
    0x1000C2658: ("adrp", "#0x100c51000"),
    0x1000C265C: ("add", "#0x8f8"),
    0x1000C2660: ("str", "[x8, #0x20]"),
    0x1000C2668: ("stp", "[x8]"),
    0x1000C2AF8: ("adrp", "#0x100c51000"),
    0x1000C2AFC: ("add", "#0x8f8"),
    0x1000C2B04: ("strb", "[x8]"),
    0x1000C2B0C: ("strb", "[x8, #1]"),
    0x1000C2B10: ("str", "[x8, #8]"),
    0x1000C2B14: ("ldur", "[x22, #0xc8]"),
    0x1000C2B1C: ("str", "[x8, #0x10]"),
    0x1000C3AD0: ("adrp", "#0x100c51000"),
    0x1000C3AD4: ("add", "#0x8f8"),
    0x1000C3AD8: ("ldp", "[x8]"),
    # showCircle + static/dynamic selector
    0x1000DE734: ("ldrb", "[x27, #0x16c]"),
    0x1000DE75C: ("ldr", "[x27, #0x1c0]"),
    0x1000DE768: ("fmov", "#1.50000000"),
    0x1000DE774: ("mov", "#0xd278"),
    0x1000DE778: ("movk", "#0xa0ff"),
    0x1000DE77C: ("mov", "#0x40"),
    # dynamic phase and four double-stroked arcs
    0x1000DE894: ("fsub", "d0, d0, d1"),
    0x1000DE8B4: ("bl", "#0x100725a40"),
    0x1000DE8C8: ("bl", "#0x100725a40"),
    0x1000DE8D8: ("bl", "#0x100725830"),
    0x1000DE990: ("mov", "#0x10"),
    0x1000DE9F4: ("cmp", "#4"),
    0x1000DEB3C: ("cmp", "#4"),
    # selected-candidate line
    0x1000DEBE8: ("ldrb", "[x27, #0x1c4]"),
    0x1000DEC1C: ("fmov", "#1.00000000"),
    0x1000DEC24: ("mov", "#0x50ff"),
    0x1000DEC28: ("movk", "#0x8250"),
    # pre-aim selected-point marker and optional second projection
    0x1000DEC30: ("ldrb", "[x27, #0x16b]"),
    0x1000DEC50: ("fmov", "#7.00000000"),
    0x1000DEC68: ("mov", "#0x50ff"),
    0x1000DEC6C: ("movk", "#0xdc50"),
    0x1000DEC70: ("mov", "#0x18"),
    0x1000DEC84: ("fmov", "#2.50000000"),
    0x1000DEC98: ("movk", "#0xdc50"),
    0x1000DEC9C: ("mov", "#0xc"),
    0x1000DECA4: ("ldr", "[x27, #0x17c]"),
    0x1000DECCC: ("cmp", "x8, x28"),
    0x1000DED48: ("fmov", "#1.50000000"),
    0x1000DED50: ("mov", "#0xd2ff"),
    0x1000DED54: ("movk", "#0xc83c"),
    0x1000DED68: ("fmov", "#5.00000000"),
    0x1000DED7C: ("mov", "#0xd2ff"),
    0x1000DED80: ("movk", "#0xe63c"),
    0x1000DED84: ("mov", "#0x10"),
}

FLOATS = {
    0x100AC8338: -1.8,
    0x100AC833C: -3.6,
    0x100AC8340: 0.13,
    0x100AC8344: -0.13,
    0x100AC8348: 5.2,
    0x100AC8264: 2.4,
    0x100AC834C: 0.54,
    0x100AC8320: 0.24,
    0x100AC82A4: 0.43,
    0x1008A9A48: 0.8,
    0x100AC8328: 0.055,
    0x100AC8350: 1.7,
    0x1008A9EB0: -1.5707964,
    0x1008A9E6C: 0.16,
    0x100AC8330: 0.04,
    0x1008A9EA0: 4.2,
    0x1008A9DC8: 1.8,
}


def analyze() -> dict:
    with zipfile.ZipFile(CORE_IPA) as archive:
        core = archive.read("Payload/Core.app/Core")
    assert sha256(core).hexdigest() == CORE_SHA256
    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    decoded = {}
    for address, expected in SITES.items():
        ins = next(decoder.disasm(core[address - BASE:address - BASE + 4], address))
        assert ins.mnemonic == expected[0] and expected[1] in ins.op_str
        decoded[address] = (ins.mnemonic, ins.op_str)
    constants = {}
    for address, expected in FLOATS.items():
        value = struct.unpack_from("<f", core, address - BASE)[0]
        assert abs(value - expected) < 0.00001
        constants[address] = value
    return {
        "core_sha256": CORE_SHA256,
        "sites": decoded,
        "floats": constants,
        "selected_marker_closed": True,
        "connection_line_closed": True,
        "static_circle_closed": True,
        "dynamic_geometry_closed": True,
        "secondary_projection_payload_closed": True,
        "device_pixels_verified": False,
    }


if __name__ == "__main__":
    result = analyze()
    print(f"PASS: aim visual {len(result['sites'])} sites, "
          f"{len(result['floats'])} constants; device pixels remain unverified")
