"""Read-only, sample-bound home producer/caller probe; never executes Core.

Reuse the established Mach-O identity reader and Objective-C method-list recipe.
Candidate ranges and local register propagation are not a whole CFG or runtime
proof. Code after the first RET is exposed separately, never presumed reachable.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import struct
import sys

import numpy as np

from core_set_v17_function_chain_probe import CoreImage, IPA_SHA, IMAGE_SHA


ROOTS = {
    "home_snapshot": 0x100004010, "kernel_action": 0x100004F00,
    "information_action": 0x10000538C, "cover_update": 0x1000D3EAC,
    "cover_global_reset": 0x1000D36A8, "pages_snapshot": 0x10004E2E4,
    "pages_atomic_get": 0x10002FD1C, "firmware_snapshot": 0x1000112D0,
    "firmware_copy": 0x100009F68, "firmware_publish": 0x10000A06C,
    "pages_worker": 0x1000336B8, "pages_control": 0x100030124,
    "pages_reset": 0x10002F9F8, "firmware_shared": 0x100009DA8,
    "firmware_download": 0x10000BFC0, "firmware_cancel": 0x100010FCC,
    "firmware_workflow_block": 0x10000F8F0,
    "configuration_get": 0x1000122A4, "configuration_set": 0x100012E34,
}
PROOF_SITES = [0x100004278, 0x100004284, 0x1000042C0, 0x1000042D0,
               0x10004E328, 0x10002FD48, 0x10002FD58, 0x10002FD64,
               0x10001131C, 0x100009FAC, 0x10000A120, 0x10000A1A8,
               0x100005474, 0x10000568C, 0x1000056C0, 0x1000D3EC4,
               0x1000D3EF4, 0x1000D3F24, 0x1000D3F28,
               0x1000111B8, 0x1000111C8, 0x1000337B4, 0x1000337C0,
               0x100033BE8, 0x100033C28, 0x1000124C8, 0x100012548,
               0x10000FF00, 0x10000FF08, 0x10000FF18, 0x10000FF24,
               0x10000D45C, 0x10000D468, 0x10000CAB0, 0x10000CBD0,
               0x10000D6CC, 0x10000D6D4, 0x10000A1A4, 0x10000A1BC]
PAGES = {0x100C20280, 0x100C20281, 0x100C20284, 0x100C20288,
         0x100C20290, 0x100C20298, 0x100C202A0}
CONFIG = {0x100C5839C, 0x100C5829F, 0x100C583A0}


def pointer(value: int) -> int:
    return 0x100000000 + (value & (0xFFFFFFFF if value >> 63 else 0x7FFFFFFFFFF))


def methods(core: CoreImage) -> list[dict]:
    def q(address):
        return struct.unpack("<Q", core.raw(address, 8))[0]
    section = core.image.get_section("__objc_classlist")
    hits = []
    for offset in range(0, section.size, 8):
        cls = pointer(q(section.virtual_address + offset))
        ro = pointer(q(cls + 32)) & ~7
        name = core.string(pointer(q(ro + 24)))
        if name not in ("QXA107", "QXA105"):
            continue
        for owner, address in (("instance", cls), ("class", pointer(q(cls)))):
            owner_ro = pointer(q(address + 32)) & ~7
            encoded = q(owner_ro + 32)
            if not encoded:
                continue
            base = pointer(encoded)
            flags, count = struct.unpack("<II", core.raw(base, 8))
            stride = flags & 0xFFFF
            assert 12 <= stride <= 32 and count < 1000
            for index in range(count):
                entry = base + 8 + index * stride
                if flags & 0x80000000:
                    selector_delta, _, implementation_delta = struct.unpack("<iii", core.raw(entry, 12))
                    selector = core.string(pointer(q(entry + selector_delta)))
                    implementation = entry + 8 + implementation_delta
                else:
                    selector = core.string(pointer(q(entry)))
                    implementation = pointer(q(entry + 16))
                if selector and (selector in ("qx327", "qx307:", "generation", "otaTotalBytes", "cancel")
                                 or selector.startswith("qm543:") or selector.startswith("qm571:")):
                    hits.append({"class": name, "owner": owner, "selector": selector,
                                 "method_entry": hex(entry), "implementation": hex(implementation)})
    return hits


def selector_stub(core: CoreImage, address: int) -> dict:
    instructions = core.instructions(address, 8)
    assert instructions[0].mnemonic == "adrp" and instructions[0].op_str.startswith("x1, #")
    assert instructions[1].mnemonic == "ldr" and instructions[1].op_str.startswith("x1, [x1,")
    page = int(instructions[0].op_str.split("#")[1], 0)
    offset = int(instructions[1].op_str.split("#")[1].split("]")[0], 0)
    slot = page + offset
    encoded = struct.unpack("<Q", core.raw(slot, 8))[0]
    return {"stub": hex(address), "selector_slot": hex(slot), "encoded": hex(encoded),
            "selector": core.string(pointer(encoded))}


def global_references(core: CoreImage) -> list[dict]:
    """Find explicit page constants, then bounded local field references.

    Volatile registers are killed at BL. No loaded pointer or branch path is
    guessed. A hit is a reference candidate, not a proven consumer lifecycle.
    """
    words = np.frombuffer(core.data, dtype="<u4", count=core.text.size // 4, offset=core.text.offset)
    starts = []
    for index in np.flatnonzero((words & 0x9F000000) == 0x90000000):
        word = int(words[index])
        immediate = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 3)
        if immediate & (1 << 20):
            immediate -= 1 << 21
        site = core.text.virtual_address + int(index) * 4
        if (site & ~0xFFF) + immediate * 4096 in (0x100C20000, 0x100C58000):
            starts.append(site)
    seen = set()
    hits = []
    key = lambda name: "x" + name[1:] if name.startswith("w") else name
    for start in starts:
        values = {}
        for instruction in core.instructions(start, 0x80):
            mnemonic, arguments = instruction.mnemonic, instruction.op_str.split(", ")
            before = values.copy()
            for register in instruction.regs_access()[1]:
                values.pop(key(instruction.reg_name(register)), None)
            if mnemonic == "adrp":
                values[key(arguments[0])] = int(arguments[1].lstrip("#"), 0)
            elif mnemonic == "add" and arguments[2].startswith("#") and key(arguments[1]) in before:
                values[key(arguments[0])] = before[key(arguments[1])] + int(arguments[2].lstrip("#"), 0)
            elif mnemonic == "mov" and len(arguments) == 2 and key(arguments[1]) in before:
                values[key(arguments[0])] = before[key(arguments[1])]
            for match in re.finditer(r"\[(x\d+)(?:, #(-?(?:0x[0-9a-f]+|\d+)))?\]", instruction.op_str):
                if match[1] not in before:
                    continue
                address = before[match[1]] + int(match[2] or "0", 0)
                if address not in PAGES | CONFIG or instruction.address in seen:
                    continue
                seen.add(instruction.address)
                hits.append({"site": hex(instruction.address), "file_offset": hex(core.file_offset(instruction.address)),
                             "global": hex(address), "kind": "read" if mnemonic.startswith("ld") else
                             "write" if mnemonic.startswith("st") else "address-use",
                             "bytes": bytes(instruction.bytes).hex(),
                             "instruction": mnemonic + " " + instruction.op_str,
                             "function_candidate": core.containing(instruction.address)})
            if mnemonic == "bl":
                for number in range(19):
                    values.pop("x" + str(number), None)
            elif mnemonic in ("ret", "retab", "retaa") or mnemonic == "b":
                break
    return sorted(hits, key=lambda hit: int(hit["site"], 16))


def probe(core: CoreImage) -> dict:
    functions = {}
    for name, address in ROOTS.items():
        function = core.describe_function(address)
        instructions = core.instructions(int(function["entry"], 16),
                                         int(function["candidate_end"], 16) - int(function["entry"], 16))
        returns = [instruction.address for instruction in instructions if instruction.mnemonic in ("ret", "retab", "retaa")]
        function["first_return_site"] = hex(returns[0]) if returns else None
        function["calls_after_first_return_not_presumed_reachable"] = [edge for edge in function["candidate_tail_calls"]
                                                                     if returns and int(edge["site"], 16) > returns[0]]
        functions[name] = function
    class_reference = pointer(struct.unpack("<Q", core.raw(0x100BD5488, 8))[0])
    class_ro = pointer(struct.unpack("<Q", core.raw(class_reference + 32, 8))[0]) & ~7
    class_name = core.string(pointer(struct.unpack("<Q", core.raw(class_ro + 24, 8))[0]))
    assert class_name == "QXA107"
    return {"schema_version": 1, "ipa_sha256": IPA_SHA, "image_sha256": IMAGE_SHA,
            "evidence_grade": "identity-bound static partial; no native execution/runtime receipt",
            "point_ids": ["v17-000", "v17-001", "v17-002", "v17-003", "v17-009", "v17-010"],
            "original_runtime_verified": False, "functions": functions,
            "objc_methods": methods(core), "global_reference_candidates": global_references(core),
            "firmware_class_reference": {"slot": "0x100bd5488", "class": class_name, "class_address": hex(class_reference)},
            "selector_stubs": [selector_stub(core, address) for address in
                               (0x10072CE60, 0x10072CDA0, 0x100729E80, 0x10072F780, 0x10072BA80, 0x1007324E0)],
            "provider_selector_edges": [selector_stub(core, address) | {
                "direct_call_sites": [core.proof_window(site, 4) for site in core.callers.get(address, [])],
                "limit": "selector-bound direct callsite; receiver dispatch/runtime callback ownership still requires observation"}
                for address in (0x10072C640, 0x10072C4A0, 0x10072C2C0)],
            "proof_windows": [core.proof_window(site) for site in PROOF_SITES],
            "progress_sources": {
                "v17-009": {"path": ["4010", "4e2e4", "2fd1c"], "phase_global": "0x100c20284",
                            "counter_globals": ["0x100c20288", "0x100c20290"], "unit": "pages",
                            "limit": "atomic fields are independent loads; no invented coherent request/generation"},
                "v17-010": {"path": ["4010", "112d0", "+[QXA107 qx327]", "-[QXA107 qx307:]"],
                            "snapshot_size": 0x170, "counter_offsets": [0x10, 0x18], "unit": "bytes",
                            "update": "qm543 rejects a supplied generation unequal to current, except explicit -1 sentinel",
                            "download_entry": "-[QXA107 qm571:fromURL:productType:buildVersion:boardConfig:client:generation:progress:error:] at0x10000bfc0",
                            "download_callsite": "0x10000ff24 in authenticated-prologue candidate0x10000f8f0; call through selector stub0x10072c640",
                            "callback_sites": ["0x10000cac0", "0x10000cbd4", "0x10000d6dc"],
                            "total_update": "d458 obtains generation; d460 compares supplied generation; only equal branch d470 setOtaTotalBytes",
                            "next_capture": "record request/epoch/sequence plus native generation raw bits; path/URL/product/build/board/client as presence or digest only; callback transferred byte count; qm543 stage/inFlight/ready/error and snapshot totalBytes; task return is not completed",
                            "limit": "current DarkSword or fetchkcache local copy is not this producer"}},
            "current_insertion_interface": "CoreSetRuntimeCoordinator.recordHomeProducerProbeEvent; diagnostics only, never FeatureChannel apply or UI progress"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path, required=True)
    parser.add_argument("--compact", action="store_true")
    arguments = parser.parse_args()
    result = probe(CoreImage(arguments.reference_ipa))
    if arguments.compact:
        result["functions"] = {name: {key: value for key, value in function.items()
                                     if key not in ("calls", "conditional_and_direct_branches")}
                               for name, function in result["functions"].items()}
        result["proof_windows"] = [{"address": window["address"], "word_count": len(window["instructions"])}
                                   for window in result["proof_windows"]]
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
