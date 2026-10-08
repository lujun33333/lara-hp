"""Sample-bound local theme/directory/performance contracts; Core is not run."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import struct
import sys

from core_set_v17_function_chain_probe import CoreImage, IPA_SHA, IMAGE_SHA
from core_set_v17_home_producer_probe import pointer


THEME_IDS = ["v17-011", "v17-012", "v17-013"] + [f"v17-{i:03}" for i in range(15, 22)]
DIRECTORY_IDS = [f"v17-{i:03}" for i in range(70, 83)]
PERFORMANCE_IDS = ["v17-030", "v17-031", "v17-032"]
FLOATING_IDS = ["v17-014"] + [f"v17-{i:03}" for i in range(22, 29)]
HOME_IDS = [f"v17-{i:03}" for i in range(4, 9)]
SITES = [0x1000CB618, 0x1000CB65C, 0x1000CB690, 0x1000CB704,
         0x1000CB808, 0x1000CB81C, 0x1000CB838, 0x1000CCA3C,
         0x1000CCE3C, 0x1000CCF04, 0x1000CCF6C, 0x1000CCF7C,
         0x1000FA648, 0x1000FA654, 0x1000FCA0C, 0x1000FCA18,
         0x1000FCA20, 0x1000FCA28, 0x1000FCA90, 0x1000FCA98, 0x1000FCAC0,
         0x1000FCAF4, 0x1000FCB14, 0x1000CD274, 0x1000CD290, 0x1000CD2AC]


def cf_string(core, address):
    encoded = struct.unpack("<Q", core.raw(address + 16, 8))[0]
    return core.string(pointer(encoded))


def probe(core):
    bits = [list(struct.unpack("<4I", core.raw(0x100AC813C + index * 16, 16))) for index in range(7)]
    theme_section = next(section for section in core.image.sections
                         if section.virtual_address <= 0x100C58868 < section.virtual_address + section.size)
    assert str(theme_section.type) == "TYPE.ZEROFILL"
    formats = {point: core.raw(address, 64).split(b"\0", 1)[0].decode("utf-8")
               for point, address in zip(PERFORMANCE_IDS, (0x100743EFD, 0x100743F11, 0x100743F27), strict=True)}
    return {"schema_version": 1, "ipa_sha256": IPA_SHA, "image_sha256": IMAGE_SHA,
            "point_ids": HOME_IDS + THEME_IDS + FLOATING_IDS + PERFORMANCE_IDS + DIRECTORY_IDS,
            "original_runtime_receipt_verified": False, "device_effect_verified": False,
            "source_same_meaning_local_contract_points": THEME_IDS + DIRECTORY_IDS + PERFORMANCE_IDS,
            "theme": {"theme_key": cf_string(core, 0x100BAF388), "accent_key": cf_string(core, 0x100BAF368),
                      "default_mode": 0, "default_basis": "Core theme global is ZEROFILL; invalid/missing NSNumber does not override",
                      "default_accent_bits": list(struct.unpack("<4I", core.raw(0x100C19A88, 16))),
                      "preset_bits": bits, "packed_byte_order": "RGBA little endian; R low byte",
                      "packed_formula": "Float32 fused c*255+0.5 then truncation; alpha forced1",
                      "unpack_scale_bits": hex(struct.unpack("<I", core.raw(0x100797620, 4))[0]),
                      "theme_setter": "0x1000c78d8", "load": "0x1000cb594", "save": "0x1000cb794"},
            "floating": {"swatch_bits": bits, "ui_to_storage": list(struct.unpack("<7i", core.raw(0x100AC81AC, 28))),
                         "fallback_storage": 5, "menu_gradient_indices": [0, 2],
                         "limit": "menu swatch/highlight/persistence only; native floating instance effect/lifecycle not closed"},
            "directory": {"selected_category_global": "0x100c52914", "changed_flag": "0x100c52918",
                          "index_range": [0, 12], "effect": "local category/content switch; reset scroll; do not rewrite group flags",
                          "limit": "category navigation is local behavior; item discovery and group filtering remain separate consumers"},
            "performance": {"formats": formats, "owner": "own process, not target game",
                            "globals": ["0x100c52988", "0x100c5298c", "0x100c52990"],
                            "primary_cpu": "THREAD_BASIC_INFO; skip TH_FLAGS_IDLE; Float32 sum(cpu_usage/1000*100)",
                            "fallback_cpu": "independent RUSAGE_SELF delta; never replaces primary or grants its valid flag",
                            "memory": "TASK_VM_INFO phys_footprint/2^20; UI writes MB but quantity is MiB",
                            "peak": "process-lifetime Float32 CAS max of phys_footprint/2^20",
                            "limit": "API/native layout and device observations still require iOS validation"},
            "system_imports": {hex(stub): resolve_import(core, stub) for stub in
                               (0x100726D00, 0x100726D40, 0x100726CF0, 0x100725C40)},
            "proof_windows": [core.proof_window(site) for site in SITES]}


def resolve_import(core, address):
    instructions = core.instructions(address, 16)
    assert instructions[0].mnemonic == "adrp" and instructions[1].mnemonic == "add"
    page = int(instructions[0].op_str.split("#")[1], 0)
    offset = int(instructions[1].op_str.split("#")[1], 0)
    return core.bindings.get(page + offset)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path, required=True)
    arguments = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(probe(CoreImage(arguments.reference_ipa)), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
