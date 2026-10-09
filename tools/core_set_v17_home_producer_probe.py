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
    "cover_global_reset": 0x1000D36A8, "cover_candidate_gate": 0x1000D7734,
    "cover_segment_gate": 0x1000D33F4, "cover_segment_query": 0x1000D3424,
    "cover_spatial_query_a": 0x1000E0BE8,
    "cover_spatial_query_b": 0x1000E0CF0,
    "cover_stop": 0x1000D3DD0, "cover_worker_a": 0x1000E3E84,
    "cover_worker_b": 0x1000EC0BC, "cover_worker_c": 0x1000EFDA8,
    "cover_collector_a": 0x1000E40F4, "cover_collector_b": 0x1000EC2F8,
    "cover_collector_c": 0x1000EFFEC,
    "cover_adapter_ac": 0x1000E5288, "cover_adapter_b": 0x1000EC834,
    "cover_callback_ac": 0x1000E10BC, "cover_callback_b": 0x1000E11A8,
    "cover_owner_publish": 0x1000D3914, "cover_record_append": 0x1000E9CE4,
    "cover_record_build_ac": 0x1000E60BC, "cover_record_build_b": 0x1000ED220,
    "pages_snapshot": 0x10004E2E4,
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
    "home_runtime": "lara/views/app/CoreSetHomeRuntimeProducer.swift",
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
        for match in re.finditer(r"(?:\bbindHomeReferenceObservationProvider|homeTelemetry\.bindReferenceObservationProvider)\s*\(", source):
            prefix = source[source.rfind("\n", 0, match.start()) + 1:match.start()]
            if re.search(r"\bfunc\s*$", prefix):
                continue
            bind_calls.append({"source": path, "line": source.count("\n", 0, match.start()) + 1})
        for match in re.finditer(r"bindGameConsumer\([^\n;]*to:\s*\\\.home\)", source):
            home_bindings.append({"source": path, "line": source.count("\n", 0, match.start()) + 1})
    evidence = {
        "home_state": [site("state", "var runMode: CoreSetRunMode?"), site("state", "var coverMode: CoreSetCoverMode?")],
        "home_run_reference_config": [site("state", "No separate native runtime"),
                                      site("menu", "reference-config-only-no-native-consumer")],
        "home_cover_refusal": [site("menu", "home.coverMode：原版只读 lease")],
        "home_action_binding": [site("menu", "var onHomeAction:"), site("menu", "startHomeKernelAction"),
                                site("menu", "startHomeInformationAction"), site("coordinator", "menu.onHomeAction ="),
                                site("coordinator", "recordHomeAction(.kernelAction"),
                                site("coordinator", "recordHomeAction(.informationAction")],
        "kernel_call": [site("coordinator", "manager.run"), site("manager", "let result = ds_run()"),
                        site("manager", "let success = result == 0 && ds_is_ready()"),
                        site("dark_sword_api", "typedef void (*ds_progress_callback_t)(double progress);")],
        "kernel_cache_call": [site("coordinator", "let fetched = fetchkcache(action: action)"),
                              site("coordinator", "let loaded = fetched && !action.isCancellationRequested && dlkcache()"),
                              site("settings", "let fetched = fetchkcache()"), site("settings", "if fetched {"),
                              site("settings", "try fm.copyItem(at: url, to: dest)"), site("settings", "ok = dlkcache()"),
        site("offsets", "identityMatches && iskcachevalid(outpath)"), site("offsets", "kc_fetch_firmware_images_by_range(outpath"),
                              site("offsets", "grab_kernelcache(outpath)"), site("offsets", "return resolvekernoffsets(outpath);")],
        "range_fetch": [site("partial", "[[CoreSetRangeVerifiedPartial alloc] initWithURL:url error:&error]"),
                        site("partial", "forHTTPHeaderField:@\"If-Range\""),
                        site("partial", "[zip size]"),
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
        "live_home_producer": [site("home_runtime", "final class CoreSetHomeRuntimeProducer: CoreSetHomeReferenceObservationProvider"),
                               site("home_runtime", "CoreSetKernelCacheTransferOwner.shared.snapshot()"),
                               site("home_runtime", "manager.dsStageObservation"),
                               site("home_runtime", "manager.dsPageObservation"),
                               site("coordinator", "let homeProducer = CoreSetHomeRuntimeProducer(manager: .shared)"),
                               site("coordinator", "homeTelemetry.bindReferenceObservationProvider(homeProducer)")],
    }
    common = "real owner/request identity, producer epoch, monotone sequence, actual host generation, fresh observation, start/update/failure/cancel/stop receipt; submission != completion"
    points = {
        "v17-000": ("reference 0/1 normalized configuration; native image has no separate consumer", ["home_state", "home_run_reference_config"],
                    "configuration storage closed; no native runtime effect to invent"),
        "v17-001": ("configuration + refused menu", ["home_state", "home_cover_refusal"],
                    "C+2f bool + C+130 int32; global/in-game/off spatial-index bootstrap for bone-segment cover-color selection, off preserves prior mode; static owner/callback/output-record ABI closed, but runtime table-row identity into builder fields and current device publication still require observation"),
        "v17-002": ("bound local action: menu -> coordinator request lifecycle -> laramgr.run -> ds_run", ["home_action_binding", "kernel_call"],
                    "4f00 gates and native token; 63a4 workflow; 6938 matching-token watchdog 240s timeout/20s stagnant counter; completed/failure cleanup parity"),
        "v17-003": ("bound local action: menu -> coordinator request lifecycle -> current-device kernelcache/offset parsing", ["home_action_binding", "kernel_cache_call"],
                    "538c host gate; nonempty named input -> 609a8 tuple -> 6cc8 0x288 information -> 60358 validation -> 648ac publish; info status1/2/3 and rollback"),
        "v17-005": ("bound live local environment producer; not original environment owner", ["kernel_call", "range_fetch", "observation_boundary", "live_home_producer"],
                    "5f14 same support classification + QXA107 phase/inFlight/ready composite environment, UTF8<=63 bytes"),
        "v17-006": ("bound live local information producer; not original named-information owner", ["kernel_cache_call", "observation_boundary", "live_home_producer"],
                    "4e00/538c status1/2/3 + optional message, validated named-information owner, UTF8<=191 bytes"),
        "v17-008": ("bound typed DarkSword stage callback producer; not original publisher", ["kernel_call", "observation_boundary", "live_home_producer"],
                    "5c6a8 lock-protected 0x168 snapshot stage buffer+0x78, UTF8<=127 bytes; running is not stage"),
        "v17-009": ("bound typed DarkSword page callback producer", ["kernel_call", "observation_boundary", "live_home_producer"],
                    "2fd1c independent acquire fields executing/cancel/phase and UInt64 completed/total PAGE counters; coherent request/phase/completion/stop proof"),
        "v17-010": ("bound kernelcache transfer byte producer / system OTA switch", ["range_fetch", "kernel_cache_call", "local_copy", "ota_switch", "observation_boundary", "live_home_producer"],
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
                        "producer_bound": point in {"v17-000", "v17-002", "v17-003", "v17-005", "v17-006", "v17-008", "v17-009", "v17-010"},
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
            "cover_bootstrap": {
                "configuration": {"enabled": "C+0x2f bool", "mode": "C+0x130 int32",
                                  "initialized": "C+0x1e9 bool"},
                "update": "d3eac publishes update flag; mode1 clears transient candidate state and enters d36a8; non-mode1 clears transient state only while not initialized",
                "global_start": "d36a8 requires enabled, not initialized, live read lease and changed generation; then creates three joinable workers and sets initialized",
                "in_game_start": "d7734 validates one 0x2a-byte candidate record, requires record+0x29, retains address/id/float state and invokes d36a8 after three stable confirmations",
                "workers": [
                    {"entry": "0x1000e3e84", "collector": "0x1000e40f4", "callback_slot": "0x100c19ec8", "adapter": "0x1000e5288", "key_callback": "0x1000e10bc"},
                    {"entry": "0x1000ec0bc", "collector": "0x1000ec2f8", "callback_slot": "0x100c19ed0", "adapter": "0x1000ec834", "key_callback": "0x1000e11a8"},
                    {"entry": "0x1000efda8", "collector": "0x1000effec", "callback_slot": "0x100c19ed8", "adapter": "0x1000e5288", "key_callback": "0x1000e10bc"}],
                "collector_record_abi": {
                    "stride": "0xa0",
                    "append": "e9ce4 move-appends exactly 0xa0 bytes: it transfers both vector owners, copies record+0x30..+0x9f, and advances destination by 0xa0",
                    "fields": [
                        {"range": "0x00..0x17", "size": 24, "type": "std::vector<float3>",
                         "producer": "geometry builders e9dc8/e9fbc/eb440", "consumer": "Embree vertex buffer FLOAT3 stride0x0c"},
                        {"range": "0x18..0x2f", "size": 24, "type": "std::vector<uint32 triangle-index>",
                         "producer": "index builders ea0c4/eb5ec", "consumer": "Embree index buffer UINT3 stride0x0c"},
                        {"range": "0x30", "size": 1, "type": "uint8 source flag",
                         "producer": "builder-row+0x1d4", "consumer": "preserved metadata; not read by Embree adapter"},
                        {"range": "0x31..0x33", "size": 3, "type": "zero padding",
                         "producer": "record zero-init", "consumer": "none observed"},
                        {"range": "0x34..0x43", "size": 16, "type": "source payload block A",
                         "producer": "builder-row+0x50", "consumer": "preserved metadata; domain name absent"},
                        {"range": "0x44..0x53", "size": 16, "type": "source payload block B",
                         "producer": "builder-row+0x60", "consumer": "preserved metadata; domain name absent"},
                        {"range": "0x54..0x57", "size": 4, "type": "zero padding",
                         "producer": "record zero-init", "consumer": "none observed"},
                        {"range": "0x58..0x67", "size": 16, "type": "derived identity payload / A-C map key",
                         "producer": "builder-row-derived temporary sp+0xd0", "consumer": "A/C callback e10bc returns x0,x1"},
                        {"range": "0x68..0x6f", "size": 8, "type": "B map key",
                         "producer": "type6 builder-row+0xa0; otherwise zero-init", "consumer": "B callback e11a8 returns x0"},
                        {"range": "0x70..0x7f", "size": 16, "type": "zero reserved",
                         "producer": "record zero-init", "consumer": "none observed"},
                        {"range": "0x80..0x83", "size": 4, "type": "uint32 shape kind",
                         "producer": "literal 3/4/5/6 selected by row geometry branch", "consumer": "record metadata"},
                        {"range": "0x84..0x93", "size": 16, "type": "derived transform float4",
                         "producer": "sp+0xe4", "consumer": "record transform; final q-store overlaps the next store at +0x90"},
                        {"range": "0x94..0x9f", "size": 12, "type": "derived transform float3",
                         "producer": "sp+0xf4", "consumer": "record transform; copied by q-store from +0x90"}],
                    "coverage": "all 0xa0 output-record bytes are assigned to a field/padding range and their immediate builder-row/temporary source; this does not prove identity continuity from the earlier 64d04 table snapshot",
                    "ac_key": "16-byte callback payload from record+0x58/+0x60 (ldp x8,x1)",
                    "b_key": "8-byte callback payload from record+0x68 (ldr x0)"},
                "collector_input_owner": {
                    "lease": "5ec60 calls64c7c; only success+valid and nonzero returned sp+0x20 is published to global0x100c58778",
                    "generation": "d37ac XORs the live generation pair and d37b8 publishes the change token to global0x100c58780",
                    "collector_base": "A/B form their runtime table address from 0x100c58778 + 0x100c58780 and perform three 8-byte 64d04 pointer reads before a 0x2490 snapshot; C receives already-collected aggregate arguments and has no direct 64d04 edge",
                    "runtime_reads": {
                        "A": "64d04 sites e4200/e4288/e42fc -> e435c reads0x2490; later e47e8/e496c copy 0xd0/0x100 candidates, but these static slices do not continuously carry one identity into builder x21+0x1d4/+0x50/+0x60/+0xa0",
                        "B": "64d04 sites ec3f0/ec478/ec4ec -> ec544 reads0x2490; helper pipeline eef98/ed1d4 reaches the same e9ce4 output ABI, but per-row identity continuity into builder x21 is not proved",
                        "C": "effec has no 64d04 call; worker C passes its aggregate containers in x0..x4 and receives the same 0xa0 record vector"},
                    "builder_pair_continuity": {
                        "A_call": "e4f84..e4fa0 passes the post-table candidate vector at sp+0xa8 and companion containers at sp+0x60 into e60bc",
                        "B_call": "ec6a4..ec6cc passes the post-table candidate vector at sp+0x48 and companion containers at sp into ed220",
                        "pair_iteration": "e60bc and ed220 iterate each input as one 16-byte pair; ldp x0,x24 selects both source pointers before either is copied",
                        "same_local_row": "for the selected pair, A e631c/e6328 copies source0 0x100 bytes and e6330/e633c copies source1 0xd0 bytes into one sp+0x250 local 0x3e0 row; B ed480/ed48c and ed494/ed4a0 is the identical pair-preserving sequence",
                        "downstream": "the same local 0x3e0 row is selected by index (A e6e88; B edfec) before geometry and 0xa0 metadata construction",
                        "limit": "this closes pair-to-local-row continuity inside both builders; it does not identify which earlier 0x2490 table row created that pair"},
                    "stop": "5ebe4 calls d3dd0 on owner failure; d3dd0 clears run/initialized state, joins all three workers, calls d3b08 to release/zero slots, and clears the table generation"},
                "callback_publication_abi": {
                    "publisher": "d3914 destroys old owners, allocates three 0x100-byte owners, constructs A/C with signed callback e10bc and B with signed callback e11a8, then publishes them to globals ec8/ed8/ed0",
                    "owner_callback_slot": "constructors first rebase x19 from owner to owner+0x10 with pre-index stp, then str x1,[x19+0x40]; effective slot is owner+0x50, matching adapter loads",
                    "A": "global0x100c19ec8; adapter e5288 invokes owner+0x50 with x0=record and captures x0,x1 as the 16-byte map key",
                    "B": "global0x100c19ed0; adapter ec834 invokes owner+0x50 with x0=record and captures x0 as the 8-byte map key",
                    "C": "global0x100c19ed8; shares adapter e5288 and callback e10bc with A",
                    "geometry_result": "adapter pairs the callback payload with the uint32 Embree geometry id before map insertion"},
                "spatial_builder_abi": {
                    "geometry": "one Embree triangle geometry per nonempty record",
                    "vertex_buffer": "type=1 slot=0 format=0x9003 FLOAT3 stride=0x0c",
                    "index_buffer": "type=0 slot=0 format=0x5003 UINT3 stride=0x0c",
                    "publish": "commit geometry, commit scene, attach geometry, release geometry; retain returned geometry id",
                    "map_entry": "A/C key16 + geometry id (0x28 node); B key64 + geometry id (0x20 node)"},
                "stop": "d3dd0 clears the shared run flag, joins all three worker threads and releases their owners",
                "segment_query": {
                    "entry": "0x1000d3424",
                    "input": "six float32 arguments interpreted as two vec3 endpoints",
                    "order": ["slot 0x100c19ec8 via 0x1000e0be8",
                              "slot 0x100c19ed0 via 0x1000e0cf0",
                              "slot 0x100c19ed8 via 0x1000e0be8"],
                    "ray_record": "origin vec3, normalized endpoint-minus-origin direction, segment length, hit index initialized to -1",
                    "result": "false when a slot is absent or all three hit indices stay -1; true on the first spatial-index hit",
                    "consumer": "frame_draw 0x1000dccac calls d33f4 with actor-record+0x1f4 and one 12-byte bone world point; the bool is stored in 0x100c5218c[boneIndex]",
                    "draw_effect": "0x1000dcd34/0x1000dcd50 read endpoint hit flags; if either endpoint is hit, 0x100c58270+0xa4 color is selected before bone segment draw",
                    "owner_limit": "read-lease/generation input owner, frame_draw bone-segment color selection, current-actor bone-index publication, complete 0xa0 output layout/immediate provenance, callback publication ABI and all three Embree builders are statically closed; 64d04 table-row identity into builder fields and device results remain unproved"},
                "proof_sites": {label: core.proof_window(address, 4) for label, address in {
                    "enabled_gate": 0x1000D36E4, "mode_gate": 0x1000D3EC4,
                    "candidate_marker": 0x1000D7954, "stable_count": 0x1000D79E8,
                    "stable_start": 0x1000D79F8, "worker_a_collect": 0x1000E3F54,
                    "worker_b_collect": 0x1000EC170, "worker_c_collect": 0x1000EFE64,
                    "worker_a_callback_load": 0x1000E3F64, "worker_b_callback_load": 0x1000EC180,
                    "worker_c_callback_load": 0x1000EFE74,
                    "worker_a_callback": 0x1000E3F84, "worker_b_callback": 0x1000EC1A0,
                    "worker_c_callback": 0x1000EFE94,
                    "callback_ac_key": 0x1000E10BC, "callback_b_key": 0x1000E11A8,
                    "owner_a_constructor": 0x1000D39A8, "owner_c_constructor": 0x1000D39CC,
                    "owner_b_constructor": 0x1000D39F0, "owner_a_publish": 0x1000D39AC,
                    "owner_c_publish": 0x1000D39D0, "owner_b_publish": 0x1000D39F4,
                    "owner_ac_base": 0x1000E10E8, "owner_ac_subobject_rebase": 0x1000E10EC,
                    "owner_b_base": 0x1000E11D0, "owner_b_subobject_rebase": 0x1000E11D4,
                    "owner_ac_callback_store": 0x1000E1104, "owner_b_callback_store": 0x1000E11EC,
                    "adapter_ac_callback_load": 0x1000E5340, "adapter_b_callback_load": 0x1000EC8EC,
                    "record_flag_copy": 0x1000E763C, "record_payload_a_copy": 0x1000E7644,
                    "record_payload_b_copy": 0x1000E764C, "record_key16_copy": 0x1000E7654,
                    "record_key64_copy": 0x1000E7660, "record_kind_copy": 0x1000E7668,
                    "record_transform4_copy": 0x1000E7670, "record_transform3_copy": 0x1000E7678,
                    "record_move_vectors": 0x1000E9D0C, "record_copy_tail": 0x1000E9D44,
                    "record_advance": 0x1000E9D64,
                    "a_read_1": 0x1000E4200, "a_read_2": 0x1000E4288,
                    "a_read_3": 0x1000E42FC, "a_table_copy": 0x1000E435C,
                    "a_row_d0": 0x1000E47E8, "a_row_100": 0x1000E496C,
                    "b_read_1": 0x1000EC3F0, "b_read_2": 0x1000EC478,
                    "b_read_3": 0x1000EC4EC, "b_table_copy": 0x1000EC544,
                    "a_builder_call": 0x1000E4FA0, "a_builder_pair": 0x1000E61B0,
                    "a_builder_source0_copy": 0x1000E6328, "a_builder_source1_copy": 0x1000E633C,
                    "a_builder_row_select": 0x1000E6E88,
                    "b_builder_call": 0x1000EC6CC, "b_builder_pair": 0x1000ED314,
                    "b_builder_source0_copy": 0x1000ED48C, "b_builder_source1_copy": 0x1000ED4A0,
                    "b_builder_row_select": 0x1000EDFEC,
                    "adapter_ac_stride": 0x1000E547C, "adapter_b_stride": 0x1000ECA28,
                    "adapter_ac_vertex_format": 0x1000E538C, "adapter_ac_index_format": 0x1000E5400,
                    "adapter_b_vertex_format": 0x1000EC938, "adapter_b_index_format": 0x1000EC9AC,
                    "adapter_ac_attach": 0x1000E5438, "adapter_b_attach": 0x1000EC9E4,
                    "input_lease_call": 0x10005EC64, "input_base_store": 0x10005EC8C,
                    "input_update": 0x10005ECC0, "input_failure_stop": 0x10005EBE4,
                    "generation_xor": 0x1000D37AC, "generation_store": 0x1000D37B8,
                    "query_wrapper_tail": 0x1000D3418,
                    "query_initialized_gate": 0x1000D33FC, "query_frame_call": 0x1000DCCAC,
                    "query_store_by_bone": 0x1000DCCC0, "query_color_first_endpoint": 0x1000DCD3C,
                    "query_color_second_endpoint": 0x1000DCD58,
                    "query_slots_present": 0x1000D34A0, "query_a": 0x1000D34D4,
                    "query_a_miss": 0x1000D34D8, "query_b": 0x1000D34F4,
                    "query_c": 0x1000D3560, "query_direction_z": 0x1000E0C34,
                    "query_distance": 0x1000E0C58, "query_hit_sentinel": 0x1000E0C7C}.items()},
                "unresolved": "the complete 0xa0 output layout/immediate builder provenance, A/B 64d04 pointer/table reads and callback publication ABI are statically closed separately; continuous identity from a specific 64d04 table row into builder x21 fields, exact game-domain names and device stop/display receipts remain unproved; do not substitute a local LOS boolean"},
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
