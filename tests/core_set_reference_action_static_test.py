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
    0x100011620: "01000014",  # Loader init thunk -> guarded table producer.
    0x10001165C: "08c15239",  # Shared once flag read at table base +0x4b0.
    0x100011700: "280100f9",  # A[index] = generated mask.
    0x10001173C: "280100f9",  # B[index] = template[index] XOR mask.
    0x10001175C: "28c11239",  # Shared once flag = 1 after all 75 entries.
    0x1000C1FC8: "1acb41f9",  # Worker controller = configuration +0x390.
    0x1000D59A8: "75ca01f9",  # Scanner publishes controller at +0x390.
    0x1000D59F4: "75ca01f9",  # Alternate scanner success publishes the same field.
    0x1000C2A84: "1d080094",  # Geometry producer call.
    0x1000C2E24: "e9292d1e",  # First-axis merge.
    0x1000C2E28: "cb292c1e",  # Second-axis merge.
    0x1000C2F4C: "e30a0094",  # Conditional transaction wrapper.
    0x1000C3914: "33008052",  # Alternate-slot selector.
    0x1000C3988: "33008052",  # Paused/confirmed alternate selector.
    0x1000C2E14: "13008052",  # Direct predecessor selects slot 65.
    0x1000C2EF4: "7f020071",  # Route selector comparison.
    0x1000C2F00: "2811889a",  # B table offset: 0x460 or 0x468.
    0x1000C2F0C: "4911899a",  # A table offset: 0x208 or 0x210.
    0x1000C2F18: "486968f8",  # Load selected B entry.
    0x1000C2F1C: "496969f8",  # Load selected A entry.
    0x1000C2F20: "290108ca",  # Decode runtime offset as A XOR B.
    0x1000C2F38: "21011a8b",  # Sink address = controller + decoded offset.
    0x1000C2F9C: "08c12191",  # Index-66 current-input read path.
    0x1000C5010: "604a00bd",  # Geometry result +0x48 producer.
    0x1000C2B20: "ea5b42bd",  # Result caller read into s10.
    0x1000C5B98: "a0010054",  # Single-axis branch.
    0x1000C5BAC: "e1020094",  # First four-byte conditional helper.
    0x1000C5C20: "c4020094",  # Second four-byte conditional helper.
    0x1000C6784: "4d6efe97",  # Four-byte conditional transaction.
}

INIT_THUNKS = (0x100011620, 0x100016520, 0x10005E394,
               0x1000C11D0, 0x1000CAEB4, 0x1000D3280)
TEMPLATE_ADDRESSES = (0x100797628, 0x1008A3490, 0x1008A3E80,
                      0x1008A9A98, 0x100AC7EE0, 0x100AC83F0)
TABLE_WRITES = ((0x100011700, 0x10001173C, 0x10001175C),
                (0x100016600, 0x10001663C, 0x10001665C),
                (0x10005E474, 0x10005E4B0, 0x10005E4D0),
                (0x1000C12B0, 0x1000C12EC, 0x1000C130C),
                (0x1000CAF94, 0x1000CAFD0, 0x1000CAFF0),
                (0x1000D3360, 0x1000D339C, 0x1000D33BC))


def macho_section(data: bytes, wanted: bytes) -> tuple[int, int, int]:
    assert struct.unpack_from("<II", data) == (0xFEEDFACF, 0x0100000C)
    cursor = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, length = struct.unpack_from("<II", data, cursor)
        assert 8 <= length <= len(data) - cursor
        if command == 0x19:
            for index in range(struct.unpack_from("<I", data, cursor + 64)[0]):
                item = cursor + 72 + index * 80
                if data[item:item + 16].split(b"\0", 1)[0] == wanted:
                    address, size = struct.unpack_from("<QQ", data, item + 32)
                    offset = struct.unpack_from("<I", data, item + 48)[0]
                    assert offset + size <= len(data)
                    return address, offset, size
        cursor += length
    raise AssertionError(f"Mach-O section not found: {wanted!r}")


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
        address, offset, size = macho_section(image, b"__text")
        for anchor, opcode in ANCHORS.items():
            assert address <= anchor < address + size
            file_offset = offset + anchor - address
            assert image[file_offset:file_offset + 4] == bytes.fromhex(opcode), hex(anchor)
        templates = []
        for template_address in TEMPLATE_ADDRESSES:
            template = image[template_address - 0x100000000:
                             template_address - 0x100000000 + 0x258]
            assert len(template) == 0x258
            assert struct.unpack_from("<Q", template, 65 * 8)[0] == 0x620
            assert struct.unpack_from("<Q", template, 66 * 8)[0] == 0x828
            templates.append(template)
        assert all(template == templates[0] for template in templates[1:])

        init_address, init_offset, init_size = macho_section(image, b"__init_offsets")
        assert init_address == 0x100733BA0
        init_entries = struct.unpack_from("<" + "I" * (init_size // 4), image, init_offset)
        init_indices = [init_entries.index(thunk - 0x100000000) for thunk in INIT_THUNKS]
        assert init_indices == [1, 4, 8, 35, 37, 40]
        assert image[0xBD8660:0xBD8B11] == bytes(0x4B1)
        for a_store, b_store, flag_store in TABLE_WRITES:
            assert image[a_store - 0x100000000:a_store - 0x100000000 + 4] == bytes.fromhex("280100f9")
            assert image[b_store - 0x100000000:b_store - 0x100000000 + 4] == bytes.fromhex("280100f9")
            assert image[flag_store - 0x100000000:flag_store - 0x100000000 + 4] == bytes.fromhex("28c11239")
        for member in archive.namelist():
            if member != "Payload/Core.app/Core" and not member.endswith(".dylib"):
                continue
            data = image if member == "Payload/Core.app/Core" else archive.read(member)
            for needle in (b"IOHIDEvent", b"AXEvent", b"BKSHID", b"hidEvent", b"handleHIDEvent"):
                position = data.find(needle)
                if position >= 0:
                    print(f"INPUT_STRING_ANCHOR member={member} fileOffset=0x{position:x} needle={needle.decode()}")
    print(f"PASS: reference image={EXPECTED_IMAGE}; {len(ANCHORS)} opcode anchors; "
          "six identical guarded templates; loader-first producer=0x100011620; slots65/66=0x620/0x828")
    print("PASS: merge w19=0/1 selects slot65/66; sink address=published controller+decoded offset")
    print("LIMIT: static Mach-O ABI only; loader execution, live controller lifetime, input concurrency and stop receipts remain open")


if __name__ == "__main__":
    main()
