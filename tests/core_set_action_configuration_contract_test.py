"""Typed action-configuration contracts only; no target effects or device claim."""

from pathlib import Path
import json
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "lara/views/app"


def read(name: str) -> str:
    return (APP / name).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for position in range(opening + 1, len(source)):
        depth += (source[position] == "{") - (source[position] == "}")
        if depth == 0:
            return source[opening + 1:position]
    raise AssertionError("unterminated body: " + signature)


class ActionConfigurationContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.state = read("CoreSetFeatureState.swift")
        cls.menu = read("CoreSetMenuViewController.swift")
        cls.aim = read("CoreSetAimConsumer.swift")
        cls.recoil = read("CoreSetRecoilConsumer.swift")

    def test_aim_points_have_22_typed_fields_and_18_live_action_fields(self):
        configured = body(self.aim, "var configurableFields:")
        fields = set(re.findall(r"\.(basicAim\w+)", configured))
        self.assertEqual(len(fields), 22)
        configurable = body(self.state, "static func configurable(for capability:")
        self.assertTrue(fields.issubset(set(re.findall(r"\.(basicAim\w+)", configurable))))
        required = body(self.state, "static func required(for capability:")
        supported = set(re.findall(r"\.(basicAim\w+)", body(self.aim, "var supportedFields:")))
        self.assertEqual(set(re.findall(r"\.(basicAim\w+)", required)), supported)
        self.assertEqual(fields - supported, {
            "basicAimPreaimCircle", "basicAimDynamicCircle",
            "basicAimShowCircle", "basicAimConnectionLine",
        })

    def test_recoil_six_points_are_typed_and_inverted_flag_is_preserved(self):
        supported = body(self.recoil, "var supportedFields:")
        fields = set(re.findall(r"\.(recoil\w+)", supported))
        self.assertEqual(len(fields), 6)
        self.assertIn("supportedFields", body(self.recoil, "var configurableFields:"))
        inverted = body(self.state, "struct CoreSetInvertedFlag:")
        self.assertIn("enabled.map { !$0 }", inverted)
        toggle = body(self.menu, "@objc private func toggleRecoilField(")
        self.assertIn("stopWhenNotFiring.enabled", toggle)
        self.assertNotIn("nativeFlag =", toggle)

    def test_aim_and_recoil_enter_one_checked_shared_writer(self):
        aim_apply = body(self.aim, "func apply(")
        self.assertIn("CoreSetIsolatedWriteProbe", self.aim)
        self.assertIn(".applied(observed:", self.aim)
        self.assertIn("result.committed", self.aim)
        recoil_apply = body(self.recoil, "func apply(")
        self.assertIn("actionConsumer.applyRecoil", recoil_apply)
        self.assertIn("submitMergedAction", self.aim)
        self.assertIn("tickRecoilOnly", self.aim)
        self.assertIn("pendingRecoilCompletion", self.aim)
        self.assertNotIn("writeControllerAction", self.recoil)
        self.assertNotIn("initWithRequestAuthority", self.recoil)
        for signature in ("private func recordAimConfiguration(",
                          "private func recordRecoilConfiguration(",
                          "@objc private func configureHomeRunMode(",
                          "@objc private func configureHomeCoverMode("):
            receipt = body(self.menu, signature)
            self.assertIn("targetEffectsCreated=0", receipt)
            self.assertNotIn("applyGame", receipt)

    def test_menu_covers_scene_custom_point_and_recoil_callbacks(self):
        for marker in (
            "configureBasicAimTrigger", "configureBasicAimRange", "configureBasicAimBots",
            "configureBasicAimLock", "configureBasicAimPoint", "configureBasicAimLockStrength",
            "toggleAimConfigurationField", "toggleRecoilField", "configureRecoilStrength",
        ):
            self.assertIn(marker, self.menu)
        controls = body(self.menu, "private func aimControls(")
        self.assertIn("state.custom.predictionMilliseconds.value != nil", controls)
        for field in (
            "basicAimPoint", "basicAimTrigger", "basicAimExcludeKnocked", "basicAimScene",
            "basicAimPredictionMilliseconds", "basicAimTakeoverPause",
            "recoilStopWhenNotFiring", "recoilVerticalStrength", "recoilHorizontalStrength",
        ):
            self.assertIn("." + field, self.menu)

    def test_home_modes_are_configuration_only_and_off_retains_prior_mode(self):
        home = body(self.state, "struct CoreSetHomeSettings:")
        self.assertIn("private(set) var retainedCoverMode", home)
        self.assertIn("if mode != .off { retainedCoverMode = mode }", home)
        run_handler = body(self.menu, "@objc private func configureHomeRunMode(")
        cover_handler = body(self.menu, "@objc private func configureHomeCoverMode(")
        for handler in (run_handler, cover_handler):
            self.assertIn("homeConfigurationAvailable", handler)
            self.assertNotIn(".applied", handler)
        self.assertIn("configured=1 confirmed=1", run_handler)
        self.assertIn("reference-config-only-no-native-consumer", run_handler)
        self.assertNotIn("onHomeProbeRefusal?(.runMode", run_handler)
        self.assertIn("onHomeProbeRefusal?(.coverMode", cover_handler)
        run_row = self.menu.split('} else if parts.count == 2 && parts[0] == "运行模式" {', 1)[1]
        run_row = run_row.split('} else if title == "全开"', 1)[0]
        self.assertIn("row.isUserInteractionEnabled = true", run_row)

    def test_137_point_ledger_names_current_configuration_entries(self):
        fixture = json.loads((ROOT / "tests/fixtures/core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
        rows = {row[0]: dict(zip(fixture["columns"], row)) for row in fixture["points"]}
        expected = {
            "v17-000": ("configureHomeRunMode", "homeRunMode"),
            "v17-001": ("configureHomeCoverMode", "homeCoverMode"),
            "v17-106": ("startBasicAim", "aimStart"),
            "v17-114": ("toggleAimConfigurationField", "aimConfigurationField"),
            "v17-131": ("toggleRecoilField", "recoilField"),
            "v17-132": ("toggleRecoilField", "recoilField"),
            "v17-133": ("toggleRecoilField", "recoilField"),
            "v17-134": ("configureRecoilStrength", "recoilStrength"),
            "v17-135": ("toggleRecoilField", "recoilField"),
            "v17-136": ("configureRecoilStrength", "recoilStrength"),
        }
        for point, (entry, hosted) in expected.items():
            self.assertEqual(rows[point]["entry"], entry)
            self.assertEqual(rows[point]["hosted_action"], hosted)
        serialized = json.dumps(fixture, ensure_ascii=False)
        self.assertNotIn("还需定义逐字段CoreSetField合同", serialized)
        self.assertIn("network freshness unproven", fixture["contracts"]["radar"]["scope"])
        preview_only = {"v17-108", "v17-110", "v17-111", "v17-112"}
        action_points = {f"v17-{index:03d}" for index in range(106, 131)} - preview_only
        self.assertTrue(all(rows[point]["consumer_contract"] == "aim" for point in action_points))
        self.assertTrue(all(rows[point]["consumer_contract"] == "aim_display_alternative"
                            for point in preview_only))
        self.assertEqual(fixture["statistics"]["source_closed_action_points"], 27)


if __name__ == "__main__":
    unittest.main(verbosity=2)
