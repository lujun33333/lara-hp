"""Read-only, sample-bound home producer/caller probe; never executes Core.

Reuse the established Mach-O identity reader and Objective-C method-list recipe.
Candidate ranges and local register propagation are not a whole CFG or runtime
proof. Code after the first RET is exposed separately, never presumed reachable.
"""
from __future__ import annotations

import argparse
import hashlib
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
    "environment_support": 0x100005F14, "information_status": 0x100004E00,
    "stage_snapshot": 0x10005C6A8, "host_snapshot": 0x100055834,
    "configuration_get": 0x1000122A4, "configuration_set": 0x100012E34,
    "kernel_workflow_block": 0x1000063A4, "kernel_watchdog_block": 0x100006938,
    "information_resolve": 0x1000609A8, "information_read": 0x100006CC8,
    "information_validate": 0x100060358, "information_publish": 0x1000648AC,
    "information_error": 0x100064B80,
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
               0x10000D6CC, 0x10000D6D4, 0x10000A1A4, 0x10000A1BC,
               0x100004204, 0x100004230, 0x100004244, 0x100004338,
               0x1000043BC, 0x100004414, 0x100004428, 0x10000444C,
               0x100004E28, 0x10005C6D0,
               0x100006964, 0x100006990, 0x1000069F0, 0x100006A00,
               0x10000645C, 0x1000054BC, 0x100005554, 0x10000566C,
               0x10000567C, 0x1000056B4, 0x1000050D4, 0x100005180]
PAGES = {0x100C20280, 0x100C20281, 0x100C20284, 0x100C20288,
         0x100C20290, 0x100C20298, 0x100C202A0}
CONFIG = {0x100C5839C, 0x100C5829F, 0x100C583A0}

CURRENT_SOURCES = {
    "coordinator": "lara/views/app/CoreSetRuntimeCoordinator.swift",
    "state": "lara/views/app/CoreSetFeatureState.swift",
    "menu": "lara/views/app/CoreSetMenuViewController.swift",
    "telemetry": "lara/views/app/CoreSetHomeTelemetrySource.swift",
    "manager": "lara/classes/laramgr.swift",
    "dark_sword_api": "lara/kexploit/darksword.h",
    "local_copy": "lara/funcs/fetchkcache.swift",
    "offsets": "lara/kexploit/offsets.m",
    "partial_api": "lara/kexploit/Partial.h",
    "partial": "lara/kexploit/Partial.m",
    "grab_api": "lara/headers/libgrabkernel2.h",
    "settings": "lara/views/app/settings/SettingsView.swift",
    "ota_view": "lara/views/tweaks/OTAView.swift",
    "ota_api": "lara/kexploit/ota.h",
    "ota": "lara/kexploit/ota.m",
    "dependency_pin": "scripts/build_ipa_pe.sh",
}


def current_source_evidence(sources: dict[str, str], swift_sources: dict[str, str],
                            dependency_present: bool) -> dict:
    """Source-only caller evidence, not a native parity assertion or compiler.

    Every required anchor must be present. Provider search is a bounded lexical
    inventory of current Swift sources, not a claim about an absent external
    archive's internal callbacks. A detected provider is never auto-promoted.
    """
    def site(owner, anchor):
        source = sources[owner]
        positions = [match.start() for match in re.finditer(re.escape(anchor), source)]
        if not positions:
            raise ValueError(f"current source anchor missing: {owner}/{anchor}")
        return {"source": CURRENT_SOURCES[owner], "anchor": anchor,
                "lines": [source.count("\n", 0, position) + 1 for position in positions]}

    manifest = [{"source": CURRENT_SOURCES[owner],
                 "sha256_utf8_text": hashlib.sha256(source.encode("utf-8")).hexdigest()}
                for owner, source in sorted(sources.items())]
    conformers, bind_calls, home_bindings = [], [], []
    for path, source in sorted(swift_sources.items()):
        # All matches retain their source location for manual resolution. The
        # declaration itself is excluded, not merely its entire source file.
        for match in re.finditer(r"\bclass\s+(\w+)\s*:[^{]*\bCoreSetHomeReferenceObservationProvider\b", source):
            conformers.append({"source": path, "class": match[1], "line": source.count("\n", 0, match.start()) + 1})
        for match in re.finditer(r"\bbindHomeReferenceObservationProvider\s*\(", source):
            prefix = source[source.rfind("\n", 0, match.start()) + 1:match.start()]
            if re.search(r"\bfunc\s*$", prefix):
                continue
            bind_calls.append({"source": path, "line": source.count("\n", 0, match.start()) + 1})
        for match in re.finditer(r"bindGameConsumer\([^\n;]*to:\s*\\\.home\)", source):
            home_bindings.append({"source": path, "line": source.count("\n", 0, match.start()) + 1})
    evidence = {
        "home_state": [site("state", "var runMode: CoreSetRunMode?"), site("state", "var coverMode: CoreSetCoverMode?")],
        "home_refusal": [site("menu", "home.runMode：未提供同义"), site("menu", "home.coverMode：未提供")],
        "home_action_binding": [site("menu", "var onHomeAction:"), site("menu", "startHomeKernelAction"),
                                site("menu", "startHomeInformationAction"), site("coordinator", "menu.onHomeAction ="),
                                site("coordinator", "recordHomeAction(.kernelAction"),
                                site("coordinator", "recordHomeAction(.informationAction")],
        "kernel_call": [site("coordinator", "manager.run"), site("manager", "let result = ds_run()"),
                        site("manager", "let success = result == 0 && ds_is_ready()"),
                        site("dark_sword_api", "typedef void (*ds_progress_callback_t)(double progress);")],
        "kernel_cache_call": [site("coordinator", "let fetched = fetchkcache()"), site("coordinator", "let loaded = fetched && dlkcache()"),
                              site("settings", "let fetched = fetchkcache()"), site("settings", "if fetched {"),
                              site("settings", "try fm.copyItem(at: url, to: dest)"), site("settings", "ok = dlkcache()"),
        site("offsets", "fileExistsAtPath:outpath"), site("offsets", "kc_fetch_firmware_images_by_range(outpath"),
                              site("offsets", "grab_kernelcache(outpath)"), site("offsets", "return resolvekernoffsets(outpath);")],
        "range_fetch": [site("partial", "[Partial partialZipWithURL:url error:&error]"), site("partial", "[zip size]"),
                        site("partial", "[zip getFileForPath:entry error:&error]"), site("partial", "成员解压后 %lu 字节"),
                        site("partial_api", "- (unsigned long long)size;"), site("partial_api", "- (NSData *)getFileForPath:(NSString *)path error:(NSError **)error;"),
                        site("grab_api", "bool grab_kernelcache(NSString *outPath);")],
        "local_copy": [site("local_copy", "read(src, rawBuffer.baseAddress!, bufferSize)"), site("local_copy", "totalBytes += n")],
        "ota_switch": [site("ota_view", "let ok = ota_set_disabled(disabled)"), site("ota_api", "bool ota_set_disabled(bool disabled);"),
                       site("ota", "NSPropertyListXMLFormat_v1_0"), site("ota", "uint64_t remaining = outData.length;"),
                       site("ota", "totalWritten += n;")],
        "observation_boundary": [site("telemetry", "protocol CoreSetHomeReferenceObservationProvider: AnyObject"),
                                 site("coordinator", "func bindHomeReferenceObservationProvider("),
                                 site("telemetry", "completedPages: nil, totalPages: nil"),
                                 site("telemetry", "downloadedBytes: nil, totalBytes: nil")],
    }
    common = "real owner/request identity, producer epoch, monotone sequence, actual host generation, fresh observation, start/update/failure/cancel/stop receipt; submission != completion"
    points = {
        "v17-000": ("configuration + refused menu", ["home_state", "home_refusal"],
                    "C+12c int32 0/1 real non-menu resource/scheduler consumer and switch/restore observation"),
        "v17-001": ("configuration + refused menu", ["home_state", "home_refusal"],
                    "C+2f bool + C+130 int32; global/in-game/off occlusion owner, off preserves prior mode, actual reset/stop result"),
        "v17-002": ("bound local action: menu -> coordinator request lifecycle -> laramgr.run -> ds_run", ["home_action_binding", "kernel_call"],
                    "4f00 gates and native token; 63a4 workflow; 6938 matching-token watchdog 240s timeout/20s stagnant counter; completed/failure cleanup parity"),
        "v17-003": ("bound local action: menu -> coordinator request lifecycle -> current-device kernelcache/offset parsing", ["home_action_binding", "kernel_cache_call"],
                    "538c host gate; nonempty named input -> 609a8 tuple -> 6cc8 0x288 information -> 60358 validation -> 648ac publish; info status1/2/3 and rollback"),
        "v17-005": ("native-ready + Partial final Bool; not original environment", ["kernel_call", "range_fetch", "observation_boundary"],
                    "5f14 same support classification + QXA107 phase/inFlight/ready composite environment, UTF8<=63 bytes"),
        "v17-006": ("hasOffsets Bool; not original named-information lifecycle", ["kernel_cache_call", "observation_boundary"],
                    "4e00/538c status1/2/3 + optional message, validated named-information owner, UTF8<=191 bytes"),
        "v17-008": ("dsrunning/free-form log; no original typed stage publisher", ["kernel_call", "observation_boundary"],
                    "5c6a8 lock-protected 0x168 snapshot stage buffer+0x78, UTF8<=127 bytes; running is not stage"),
        "v17-009": ("DarkSword double fraction; no same-request page pair", ["kernel_call", "observation_boundary"],
                    "2fd1c independent acquire fields executing/cancel/phase and UInt64 completed/total PAGE counters; coherent request/phase/completion/stop proof"),
        "v17-010": ("Partial final decompressed length / local-copy bytes / system OTA switch", ["range_fetch", "kernel_cache_call", "local_copy", "ota_switch", "observation_boundary"],
                    "qm571 transferred-byte callback and asset total in same units -> qm543 snapshot, native generation/sentinel; cancel increments generation; URL/path/client presence or digest only"),
    }
    return {"evidence_grade": "current source lexical/caller contract; no external archive, runtime or native effect proof",
            "source_manifest": manifest, "caller_evidence": evidence,
            "provider_scan": {"scope": "lara/**/*.swift", "files": len(swift_sources),
                              "manifest_sha256": hashlib.sha256(json.dumps(
                                  [(path, hashlib.sha256(source.encode('utf-8')).hexdigest())
                                   for path, source in sorted(swift_sources.items())], separators=(",", ":")).encode()).hexdigest(),
                              "conformers": conformers, "binding_calls": bind_calls, "home_consumer_bindings": home_bindings,
                              "limit": "lexical candidates only; new candidate requires semantic audit, never auto-ready"},
            "external_partial": {"present": dependency_present,
                                 "pin": site("dependency_pin", "GRABKERNEL_COMMIT=e015c73aee6c2d3f6b0aad3fa629fe4c0429b7a6"),
                                 "archive_sha256_pin": site("dependency_pin", "GRAB_PARTIAL_SHA256=83aea6edd5d538bf72a91ec8feb4847eb2ae99612e56fd9aa61ee9dfccca3241"),
                                 "limit": "declared ABI has no progress/request/generation callback; absent checkout is NOT proof of absent internal functionality"},
            "points": [{"id": point, "reference_evidence_key": "native-v17/" + point,
                        "current_candidate": candidate, "caller_evidence_keys": keys,
                        "missing_same_meaning_interface": requirement, "receipt_constraints": common,
                        "producer_bound": point in {"v17-002", "v17-003"},
                        "original_runtime_receipt_verified": False}
                       for point, (candidate, keys, requirement) in points.items()]}


def probe_current_repository(root: Path) -> dict:
    sources = {owner: (root / path).read_text(encoding="utf-8") for owner, path in CURRENT_SOURCES.items()}
    swift_sources = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
                     for path in (root / "lara").rglob("*.swift")}
    return current_source_evidence(sources, swift_sources,
        (root / "build/deps/libgrabkernel2/_external/lib/ios/libpartial.a").is_file())


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
            "point_ids": [f"v17-{point:03}" for point in range(11)],
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
            "action_lifecycle": {
                "v17-002": {"entry": "0x100004f00", "worker_block": "0x1000063a4",
                            "watchdog_block": "0x100006938", "token_global": "0x100c20080",
                            "watchdog": "6938 acquire token equals captured block+0x38; 240s overall timeout; 20s unchanged page progress; different token exits without acting",
                            "block_setup_sites": ["0x1000050d4", "0x100005180"],
                            "stage_worker": "646c prepares result; 6470 calls5c6a0; 6474..6480 copies0x168 via memcpy; callback65f8 submits operation4 with captured token",
                            "unresolved": "5c6a0 provider identity/stop and60b0 operation4 response ownership/cleanup are not proved by these slices",
                            "current_limit": "laramgr Bool/global fraction and Coordinator launch/180s offset epoch do not establish this action's lifecycle"},
                "v17-003": {"entry": "0x10000538c", "typed_edges": [
                    {"site": "0x1000054c8", "callee": "0x1000609a8", "input": "nonempty UTF8 input; w1=1; 0x30 tuple result via x8"},
                    {"site": "0x100005560", "callee": "0x100006cc8", "input": "tuple[0] and zeroed0x288 information buffer"},
                    {"site": "0x100005674", "callee": "0x100060358", "input": "tuple address and UTF8 name; false branch clears tuple/cache"},
                    {"site": "0x100005684", "callee": "0x1000648ac", "input": "tuple+8 pair and tuple+0x28 count; only validated branch publishes status2"}],
                            "rollback": "5698..56b0 zero tuple/cache; 56bc calls64b80(error); 56c8 calls6274(3)",
                            "current_limit": "dlkcache resolves this device's kernel offsets; it is not this named-information pipeline"}},
            "status_semantics": {
                "v17-004": {"snapshot_offset": "0x114", "status_owner": "lock-protected global0x100c20078 int32",
                            "strings": [core.string(address) for address in (0x10073A4B8, 0x10073A48B, 0x10073A498, 0x10073A4A8, 0x10073A47B)],
                            "current": "laramgr running/failed/attempted + two ds_is_ready readings; same-meaning local init observation, not original4f00 action receipt"},
                "v17-005": {"snapshot_offset": "0x2e4", "sources": ["5f14 system-support classification", "QXA107 inFlight/ready/phase"],
                            "strings": [core.string(address) for address in (0x10073ACB2, 0x10073ACC5, 0x10073ACD5, 0x10073ACE8, 0x10073AD70, 0x10073AD54, 0x10073ACFE)],
                            "current": "reference provider unbound; nativeReady is NOT this environment"},
                "v17-006": {"snapshot_offset": "0x464", "source": "4e00 formats int32 global0x100c56da0 and optional message; action538c owns lifecycle",
                            "current": "reference provider unbound; target read identity is NOT this status"},
                "v17-007": {"snapshot_offset": "0x584", "source": "55834 host snapshot state0==1 plus byte5/byte7 branches",
                            "strings": [core.string(address) for address in (0x10073AD80, 0x10073AD99)],
                            "current": "actual local host geometry/panel/registration/cleanup observation, not remote device pixel proof"},
                "v17-008": {"snapshot_offset": "0x144", "source": "5c6a8 lock + memcpy0x168 from0x100c2c3b8; string buffer+0x78",
                            "current": "reference stage provider unbound; running alone is NOT the original stage buffer"}},
            "current_insertion_interface": "CoreSetRuntimeCoordinator.recordHomeProducerProbeEvent; diagnostics only, never FeatureChannel apply or UI progress"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    parser.add_argument("--current-sources", action="store_true", help="inspect current source callers without executing them")
    parser.add_argument("--compact", action="store_true")
    arguments = parser.parse_args()
    if not arguments.reference_ipa and not arguments.current_sources:
        parser.error("provide --reference-ipa and/or --current-sources")
    result = probe(CoreImage(arguments.reference_ipa)) if arguments.reference_ipa else {}
    if arguments.current_sources:
        result["current_sources"] = probe_current_repository(Path(__file__).resolve().parents[1])
    if arguments.compact and arguments.reference_ipa:
        result["functions"] = {name: {key: value for key, value in function.items()
                                     if key not in ("calls", "conditional_and_direct_branches")}
                               for name, function in result["functions"].items()}
        result["proof_windows"] = [{"address": window["address"], "word_count": len(window["instructions"])}
                                   for window in result["proof_windows"]]
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
