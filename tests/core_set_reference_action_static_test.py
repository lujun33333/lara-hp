"""Bound a Core v1.7 action checkpoint to its exact reference bytes.

Run with --reference-ipa PATH. This reads ZIP members in memory and writes
no artifact; opcode equality is static evidence, not target action readiness.
"""

import argparse
from hashlib import sha256
from pathlib import Path
import struct
import zipfile


EXPECTED_IPA = "57412d36a1092931d81a9a820c57eb5c1eb92dcf77076ce865dc95035a3a41cb"
EXPECTED_IMAGE = "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
ANCHORS = {
    0x1000C2A84: "1d080094",  # Geometry producer call.
    0x1000C2E24: "e9292d1e",  # First-axis merge.
    0x1000C2E28: "cb292c1e",  # Second-axis merge.
    0x1000C2F4C: "e30a0094",  # Conditional transaction wrapper.
    0x1000C3914: "33008052",  # Alternate-slot selector.
    0x1000C2F9C: "08c12191",  # Index-66 current-input read path.
    0x1000C5010: "604a00bd",  # Geometry result +0x48 producer.
    0x1000C2B20: "ea5b42bd",  # Result caller read into s10.
    0x1000C5B98: "a0010054",  # Single-axis branch.
    0x1000C5BAC: "e1020094",  # First four-byte conditional helper.
    0x1000C5C20: "c4020094",  # Second four-byte conditional helper.
    0x1000C6784: "4d6efe97",  # Four-byte conditional transaction.
}


def text_section(data: bytes) -> tuple[int, int, int]:
    assert struct.unpack_from("<II", data) == (0xFEEDFACF, 0x0100000C)
    cursor = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, length = struct.unpack_from("<II", data, cursor)
        assert 8 <= length <= len(data) - cursor
        if command == 0x19:
            for index in range(struct.unpack_from("<I", data, cursor + 64)[0]):
                item = cursor + 72 + index * 80
                if data[item:item + 16].split(b"\0", 1)[0] == b"__text":
                    address, size = struct.unpack_from("<QQ", data, item + 32)
                    offset = struct.unpack_from("<I", data, item + 48)[0]
                    assert offset + size <= len(data)
                    return address, offset, size
        cursor += length
    raise AssertionError("ARM64 __text not found")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    arguments = parser.parse_args()
    if arguments.reference_ipa is None:
        print("SKIP: pass --reference-ipa to verify the external reference sample")
        return
    with arguments.reference_ipa.open("rb") as source:
        digest = sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    assert digest.hexdigest() == EXPECTED_IPA, "reference container identity mismatch"
    with zipfile.ZipFile(arguments.reference_ipa) as archive:
        image = archive.read("Payload/Core.app/Core")
        assert sha256(image).hexdigest() == EXPECTED_IMAGE, "reference image identity mismatch"
        address, offset, size = text_section(image)
        for anchor, opcode in ANCHORS.items():
            assert address <= anchor < address + size
            file_offset = offset + anchor - address
            assert image[file_offset:file_offset + 4] == bytes.fromhex(opcode), hex(anchor)
        assert struct.unpack_from("<Q", image, 0x797628 + 65 * 8)[0] == 0x620
        assert struct.unpack_from("<Q", image, 0x797628 + 66 * 8)[0] == 0x828
        for member in archive.namelist():
            if member != "Payload/Core.app/Core" and not member.endswith(".dylib"):
                continue
            data = image if member == "Payload/Core.app/Core" else archive.read(member)
            for needle in (b"IOHIDEvent", b"AXEvent", b"BKSHID", b"hidEvent", b"handleHIDEvent"):
                position = data.find(needle)
                if position >= 0:
                    print(f"INPUT_STRING_ANCHOR member={member} fileOffset=0x{position:x} needle={needle.decode()}")
    print(f"PASS: reference image={EXPECTED_IMAGE}; {len(ANCHORS)} opcode anchors; slots65/66=0x620/0x828")
    print("LIMIT: static checkpoint only; picker, mode transitions, input concurrency and stop receipts remain open")


if __name__ == "__main__":
    main()
