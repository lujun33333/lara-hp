import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def load_probe():
    path = ROOT / "tools/core_set_v17_aim_visual_probe.py"
    spec = importlib.util.spec_from_file_location("core_set_v17_aim_visual_probe", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CoreSetAimVisualParityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = read("lara/views/app/CoreSetAimDisplayConsumer.swift")
        cls.preview = read("lara/views/app/CoreSetAimPreviewConsumer.swift")
        cls.action = read("lara/views/app/CoreSetAimConsumer.swift")
        cls.bridge_header = read("lara/overlay/CoreSetIsolatedWriteProbe.h")
        cls.bridge = read("lara/overlay/CoreSetIsolatedWriteProbe.mm")
        cls.evidence = load_probe().analyze()

    def test_hash_bound_core_sites_and_constants(self) -> None:
        self.assertEqual(self.evidence["core_sha256"],
                         "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5")
        self.assertEqual(len(self.evidence["sites"]), 50)
        self.assertEqual(len(self.evidence["floats"]), 17)
        self.assertTrue(self.evidence["selected_marker_closed"])
        self.assertTrue(self.evidence["connection_line_closed"])
        self.assertTrue(self.evidence["static_circle_closed"])
        self.assertTrue(self.evidence["dynamic_geometry_closed"])
        self.assertTrue(self.evidence["secondary_projection_payload_closed"])
        self.assertFalse(self.evidence["device_pixels_verified"])

    def test_static_circle_uses_core_segments_color_and_width(self) -> None:
        for token in ("segments: 64", "120.0 / 255", "210.0 / 255",
                      "alpha: 160.0 / 255", "width: 1.5"):
            self.assertIn(token, self.source)
        self.assertNotIn("color: .systemCyan", self.source)

    def test_connection_line_uses_core_color_and_width(self) -> None:
        block = self.source.split("if state.connectionLine == true", 1)[1].split(
            "if state.preaimMarker == true", 1)[0]
        for token in ("green: 80.0 / 255", "blue: 80.0 / 255",
                      "alpha: 130.0 / 255", "lineWidth: 1"):
            self.assertIn(token, block)
        self.assertNotIn("systemOrange", block)

    def test_selected_preaim_marker_uses_core_double_layer(self) -> None:
        block = self.source.split("if state.preaimMarker == true", 1)[1].split(
            "return result", 1)[0]
        for token in ("radius: 7", "segments: 24", "width: 1.8",
                      "alpha: 220.0 / 255", "target.point.x - 2.5",
                      "width: 5, height: 5", "filled: true"):
            self.assertIn(token, block)

    def test_live_dynamic_phase_is_not_artificially_clamped(self) -> None:
        dynamic_elapsed = self.source.split("private func dynamicElapsed", 1)[1].split(
            "private func appendLine", 1)[0]
        self.assertIn("return elapsed", dynamic_elapsed)
        self.assertNotIn("min(elapsed, 10)", dynamic_elapsed)

    def test_c4af8_predicted_world_point_is_exposed_after_plan(self) -> None:
        self.assertIn("CoreSetWorldPoint *predictedWorldPoint", self.bridge_header)
        for token in ("configuration.predictionMilliseconds >= 1.0",
                      "observed.numerical[11]", "observed.numerical[12]",
                      "observed.numerical[13]", "result.predictedWorldPoint"):
            self.assertIn(token, self.bridge)
        tick = self.action.split("private func tick(", 1)[1].split(
            "private func publish(", 1)[0]
        self.assertLess(tick.index("let step = dynamics.plan"),
                        tick.index("publishDisplayTarget(mark: freshMark"))
        self.assertIn("step: CoreSetBasicAimDelta", self.action)
        self.assertIn("predictedWorldPoint: predictedWorldPoint", self.action)
        self.assertIn("predictedScreenPoint: predictedScreenPoint", self.action)

    def test_secondary_projection_preserves_identity_and_core_geometry(self) -> None:
        for token in ("let predictedWorldPoint: CoreSetAimDisplayWorldPoint?",
                      "let predictedScreenPoint: CGPoint?",
                      "if let world = record.predictedWorldPoint",
                      "let projected = record.predictedScreenPoint",
                      "predictedWorldPoint: predictedWorldPoint",
                      "predictedPoint: predictedPoint"):
            self.assertIn(token, self.preview)
        block = self.source.split("if let predicted = target.predictedPoint", 1)[1].split(
            "return result", 1)[0]
        for token in ("green: 210.0 / 255", "blue: 60.0 / 255",
                      "alpha: 200.0 / 255", "width: 1.5",
                      "alpha: 230.0 / 255", "radius: 5", "segments: 16"):
            self.assertIn(token, block)


if __name__ == "__main__":
    unittest.main()
