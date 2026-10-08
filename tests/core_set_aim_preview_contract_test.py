import json
import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def has_target_receipt_gate(source: str) -> bool:
    marker = "if needsTarget(pending.1), expectedTargetPresent != true"
    if marker not in source:
        return False
    guarded = source.split(marker, 1)[1].split("pendingApply = nil", 1)[0]
    return "armRefresh()" in guarded and ".applied" not in guarded


class CoreSetAimPreviewContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.display = read("lara/views/app/CoreSetAimDisplayConsumer.swift")
        cls.preview = read("lara/views/app/CoreSetAimPreviewConsumer.swift")
        cls.action = read("lara/views/app/CoreSetAimConsumer.swift")
        cls.menu = read("lara/views/app/CoreSetMenuViewController.swift")
        fixture = json.loads(read("tests/fixtures/core_set_v17_menu_point_map.json"))
        cls.columns = fixture["columns"]
        cls.aim_points = [dict(zip(cls.columns, row)) for row in fixture["points"]
                          if row[1] == "自瞄"]

    def test_v17_aim_inventory_is_exactly_25_points(self) -> None:
        self.assertEqual([point["id"] for point in self.aim_points],
                         [f"v17-{index:03d}" for index in range(106, 131)])

    def test_reference_ranges_and_preview_subset_are_explicit(self) -> None:
        ranges = {point["title"]: point["reference_range"] for point in self.aim_points}
        self.assertEqual(ranges["自瞄圈大小"], [30, 525])
        self.assertEqual(ranges["最大距离"], [10, 500])
        self.assertEqual(ranges["自瞄强度"], [5, 100])
        self.assertEqual(ranges["转动平滑"], [1, 10])
        self.assertEqual(ranges["接管确认帧数"], [1, 6])
        self.assertEqual(ranges["水平速度"], [30, 720])
        self.assertEqual(ranges["垂直速度"], [30, 720])
        self.assertEqual(ranges["预判提前"], [0, 300])
        self.assertEqual(ranges["锁定门槛"], [5, 500])
        self.assertEqual(ranges["接管暂停"], [50, 1000])
        preview_titles = {point["title"] for point in self.aim_points
                          if point["alternative_preview_field"]}
        self.assertEqual(preview_titles, {"预瞄标记圈", "动态自瞄圈", "显示自瞄圈",
                                          "自瞄连接线", "自瞄圈大小", "瞄准人机", "最大距离"})

    def test_target_dependent_preview_never_applies_without_target_evidence(self) -> None:
        self.assertIn("expectedTargetPresent = frame?.target != nil", self.display)
        self.assertIn("reason=no-target-evidence commands=\\(count)", self.display)
        self.assertTrue(has_target_receipt_gate(self.display))

    def test_negative_missing_target_gate_is_rejected(self) -> None:
        altered = self.display.replace(
            "if needsTarget(pending.1), expectedTargetPresent != true",
            "if false", 1)
        self.assertFalse(has_target_receipt_gate(altered))

    def test_independent_circle_is_not_erased_by_missing_candidate(self) -> None:
        commands = self.display.split("private func commands(", 1)[1].split(
            "private func submit(", 1)[0]
        no_target = commands.split("if targetRequired && frame?.target == nil", 1)[1].split(
            "var result", 1)[0]
        self.assertNotRegex(no_target, r"return\s+\[\]")
        self.assertIn("state.circleVisible == true", commands)

    def test_preview_is_read_only_and_action_consumer_remains_fail_closed(self) -> None:
        self.assertIn("includeBattleInputs: false", self.preview)
        self.assertIn("preview-snapshot-confirmed target=", self.preview)
        self.assertNotRegex(self.preview, r"\b(ds_kwrite|vm_write|mach_vm_write|RemoteCall)\b")
        self.assertRegex(self.action, r"var supportedFields: Set<CoreSetField> \{ \[\] \}")
        self.assertIn("未执行目标写入", self.action)

    def test_v17_aim_option_text_is_preserved(self) -> None:
        self.assertIn(
            'UISegmentedControl(items: ["仅开镜", "仅开火", "开镜或开火", "开镜且开火"])',
            self.menu)
        self.assertIn(
            'UISegmentedControl(items: ["强锁定", "中锁定", "轻锁定"])',
            self.menu)
        aim_page = self.menu.split('case 5:', 1)[1].split('default:', 1)[0]
        self.assertNotIn('LOS掩体判断', aim_page)

    def test_total_switch_is_single_control_and_preserves_stop_lifecycle(self) -> None:
        controls = self.menu.split("private func aimControls(", 1)[1].split(
            "private func rebuildPage(", 1)[0]
        self.assertEqual(controls.count('setTitle("自瞄总开关"'), 1)
        self.assertNotIn('setTitle("启用自瞄"', controls)
        self.assertNotIn('setTitle("关闭自瞄"', controls)
        for marker in ("restorationNeedsStop", "restoration == .pending",
                       "#selector(stopBasicAim)", "#selector(startBasicAim)",
                       "registerHosted(totalSwitch, .aimStop)",
                       "registerHosted(totalSwitch, .aimStart)"):
            self.assertIn(marker, controls)
        self.assertIn("目标写消费者仍未启用", controls)
        stop = self.menu.split("@objc private func stopBasicAim()", 1)[1].split(
            "private func aimControls(", 1)[0]
        after_receipt = stop.split("receiveStop(token, outcome: outcome)", 1)[1]
        self.assertIn("updateDesired { $0.enabled = false }", after_receipt)
        self.assertIn("restoration == .confirmed", after_receipt)


if __name__ == "__main__":
    unittest.main()
