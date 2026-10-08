"""Source contracts and optional sample replay; no iOS/UI execution."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, anchor):
    start = source.index("{", source.index(anchor)); end = start + 1; depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}"); end += 1
    return source[start + 1:end - 1]


class LocalBehaviorContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.menu = (ROOT / "lara/views/app/CoreSetMenuViewController.swift").read_text(encoding="utf-8")
        cls.state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")
        cls.sampler = (ROOT / "lara/overlay/CoreSetPerformanceSampler.mm").read_text(encoding="utf-8")

    def test_reference_storage_with_legacy_read_only_fallback(self):
        for key in ("OKDemo_MenuTheme", "OKDemo_MenuAccentColorV1"):
            self.assertIn(key, self.state)
        self.assertIn("UInt64(value.accent.referencePackedRGBA)", self.menu)
        self.assertIn("storedPackedAccent(), saved == color.referencePackedRGBA", self.menu)
        self.assertIn("number.uint32Value", body(self.menu, "func storedPackedAccent()"))
        self.assertIn("number.doubleValue.isFinite", body(self.menu, "func storedPackedAccent()"))
        self.assertIn("number.intValue", body(self.menu, "func storedTheme()"))
        self.assertIn("object(forKey: accentKey) != nil { return nil }", self.menu)
        self.assertNotIn("UserDefaults.standard.set", body(self.menu, "func storedColor("))

    def test_original_float_bits_opaque_pack_and_no_guessed_default(self):
        self.assertIn("Float(0.5).addingProduct(Float(value), 255)", self.state)
        self.assertIn("0x3b808081", self.state)
        self.assertIn("color?.referenceOpaque", self.state)
        self.assertIn("CoreSetReferenceMenuAppearance.preset(6)", self.menu)
        self.assertIn("CoreSetReferenceMenuAppearance.preset(sender.tag)", self.menu)
        self.assertIn("if $0.theme == nil { $0.theme = storedTheme() }", self.menu)
        rows = body(self.menu, "func localColorRows(")
        self.assertIn("matchesPreset(CoreSetReferenceMenuAppearance.preset(index))", rows)
        self.assertNotIn("matchesPreset(rgb)", rows)
        match = body(self.menu, "func matchesPreset(")
        self.assertIn("CGFloat(preset.red)", match)
        self.assertNotIn("/ 255", match)

    def test_directory_receipt_is_not_accessibility_text_parser(self):
        observe = body(self.menu, "func observeDirectory()")
        self.assertIn("buttons.map(\\.observedSelection)", observe)
        self.assertNotIn("accessibilityValue", observe)
        self.assertIn("materialCatalog[category.rawValue]", observe)
        self.assertIn("selectedTab.accessibilityTraits.contains(.selected)", observe)
        select = body(self.menu, "func selectMaterialCategory(")
        self.assertLess(select.index("materialGrid.contentOffset = .zero"), select.index("applyLocalDirectory()"))
        self.assertNotIn("editMaterials", select)

    def test_local_stop_matched_and_preferences_retained(self):
        stop = body(self.menu, "func suspendGameConsumers(")
        self.assertIn("stopLocal(\\.appearanceChannel", stop)
        self.assertIn("stopLocal(\\.directoryChannel", stop)
        self.assertIn("receiveStop(token, outcome: outcome)", stop)
        self.assertIn("self.appearanceChannel?.restoration", stop)
        configure = body(self.menu, "func configureLocalConsumers()")
        self.assertIn("cleared ? .restored : .failed", configure)
        self.assertIn("persisted-config-retained=1", configure)
        self.assertNotIn("removeObject", configure)

    def test_primary_thread_cpu_and_no_fallback_promotion(self):
        for gate in ("task_threads(mach_task_self()", "THREAD_BASIC_INFO", "TH_FLAGS_IDLE", "infoCount < THREAD_BASIC_INFO_COUNT"):
            self.assertIn(gate, self.sampler)
        self.assertIn("mach_port_deallocate(mach_task_self(), threads[index])", self.sampler)
        self.assertIn("vm_deallocate(mach_task_self()", self.sampler)
        self.assertIn("result.fallbackCPUPercent = percent", self.sampler)
        self.assertNotIn("result.cpuPercent = percent", self.sampler)
        self.assertIn("fallback-does-not-confirm-primary=1", self.sampler)

    def test_footprint_peak_and_three_independent_valid_fields(self):
        self.assertIn("TASK_VM_INFO", self.sampler)
        self.assertIn("count >= TASK_VM_INFO_REV1_COUNT", self.sampler)
        self.assertIn("vm.phys_footprint", self.sampler)
        self.assertNotIn("resident_size", self.sampler)
        self.assertIn("std::atomic<float> CSPeakFootprintMiB", self.sampler)
        for flag in ("cpuValid", "footprintValid", "peakValid"):
            self.assertIn("sample." + flag, body(self.menu, "func updatePerformanceObservation("))
        self.assertIn("compare_exchange_weak", (ROOT / "lara/overlay/CoreSetPerformanceMetrics.h").read_text(encoding="utf-8"))
        self.assertIn("CSPeakProcessID != pid", self.sampler)
        self.assertIn("if (CSHasPeakObservation)", self.sampler)

    def test_exact_point_scope_and_observation_not_device_receipt(self):
        matrix = json.loads((ROOT / "tests/fixtures/core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
        proof = matrix["reference"]["local_behavior_probe"]
        expected = [11, 12, 13] + list(range(15, 22)) + [30, 31, 32] + list(range(70, 83))
        ids = {f"v17-{index:03}" for index in expected}
        self.assertEqual(set(proof["source_same_meaning_local_contract_points"]), ids)
        self.assertEqual(len(proof["remaining_local_or_observation_points"]), 13)
        self.assertFalse(proof["device_effect_verified"])
        self.assertFalse(proof["original_runtime_receipt_verified"])
        rows = {row[0]: dict(zip(matrix["columns"], row)) for row in matrix["points"]}
        for point in ids:
            self.assertEqual(rows[point]["current_implementation_status"], "same-meaning-local-source-contract / native-device-effect-unverified")
            self.assertFalse(rows[point]["device_effect_verified"])
        self.assertEqual(rows["v17-031"]["configuration"], "performanceSnapshot.footprintMiB")
        self.assertEqual(rows["v17-032"]["configuration"], "performanceSnapshot.peakFootprintMiB")
        observe = body(self.menu, "func refreshPerformanceLabels()")
        self.assertIn("performanceValueLabels[index].text == display", observe)
        self.assertIn("original-runtime-receipt=0 device-effect-verified=0", observe)
        self.assertIn("values[index] != nil", observe)
        self.assertNotIn("fallbackCPU", body(self.menu, "func performanceValues()"))


def replay(path):
    sys.path.insert(0, str(ROOT / "tools"))
    from core_set_v17_function_chain_probe import CoreImage
    from core_set_v17_local_behavior_probe import probe
    core = CoreImage(path); evidence = probe(core)
    assert len(evidence["point_ids"]) == len(set(evidence["point_ids"])) == 39
    assert len(evidence["source_same_meaning_local_contract_points"]) == 26
    assert not evidence["device_effect_verified"] and not evidence["original_runtime_receipt_verified"]
    state = (ROOT / "lara/views/app/CoreSetFeatureState.swift").read_text(encoding="utf-8")
    bits_text = state.split("static let presetBits:", 1)[1].split("static func preset", 1)[0]
    actual = [int(value, 16) for value in re.findall(r"0x[0-9a-f]+", bits_text)]
    expected = [component for color in evidence["theme"]["preset_bits"] for component in color[:3]]
    assert actual == expected
    assert evidence["theme"]["default_accent_bits"] == evidence["theme"]["preset_bits"][6]
    assert evidence["theme"]["theme_key"] == "OKDemo_MenuTheme"
    assert evidence["theme"]["accent_key"] == "OKDemo_MenuAccentColorV1"
    assert evidence["theme"]["unpack_scale_bits"] == "0x3b808081"
    assert evidence["floating"]["ui_to_storage"] == [6, 4, 1, 0, 2, 3, 5]
    assert list(evidence["system_imports"].values()) == ["_task_threads", "_thread_info", "_task_info", "_getrusage"]
    assert core.proof_window(0x1000fcabc, 4)["instructions"][0]["instruction"] == "adrp x8, #0x100c52000"
    assert core.proof_window(0x1000fca34, 4)["instructions"][0]["instruction"] == "fmadd s8, s0, s1, s8"
    assert evidence["performance"]["globals"] == ["0x100c52988", "0x100c5298c", "0x100c52990"]
    for window in evidence["proof_windows"]:
        for instruction in window["instructions"]:
            assert core.raw(int(instruction["address"], 16), 4).hex() == instruction["bytes"]
    print(f"REPLAY: 39 local/observation IDs, 26 source same-meaning local contracts, {len(evidence['proof_windows'])*4} words; device closure=0")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--reference-ipa", type=Path); arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LocalBehaviorContract))
    if not result.wasSuccessful(): raise SystemExit(1)
    if arguments.reference_ipa: replay(arguments.reference_ipa)
    else: print("SKIP: original sample replay requires --reference-ipa")
    print("LIMIT: source/static math contracts only; no Swift/UIKit/Objective-C build or device observations")
