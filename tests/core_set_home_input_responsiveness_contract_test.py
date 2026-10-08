"""Main-thread responsiveness contracts; source-only, no UIKit timing claim."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[opening + 1:index]
    raise AssertionError(signature)


def require_responsive_contract(coordinator, telemetry, menu):
    timer = coordinator[coordinator.index("let observationTimer ="):coordinator.index("self.observationTimer =")]
    assert "repeating: .milliseconds(500)" in timer
    assert "refreshPeriodicObservations()" in timer
    assert "publishStatus()" not in timer
    periodic = body(coordinator, "private func refreshPeriodicObservations()")
    assert "refreshHomeObservation()" in periodic
    assert "consumer.refreshObservation" not in periodic
    performance = body(coordinator, "private func startPerformanceSampling()")
    assert "updatePerformanceObservation(sample)" in performance
    assert "publishStatus()" not in performance

    rebuild = body(menu, "private func rebuildMenu(")
    for gate in ("hostedPointerID != nil", "hostedDispatchControlID != nil", "trackingUIKitSlider != nil"):
        assert gate in rebuild
    handler = body(menu, "func handleHostedControl(")
    assert "DispatchQueue.main.async" in handler
    assert "self.hostedDispatchControlID == nil" in handler

    assert "producerLogSignatures[field] != logSignature" in telemetry
    assert "homeFieldStateLogSignatures[point] != logSignature" in menu
    assert "hostedPaletteLogSignatures[point] != logSignature" in menu
    assert "performanceLogSignatures[point] != logSignature" in menu


class HomeInputResponsivenessContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        read = lambda p: (ROOT / p).read_text(encoding="utf-8")
        cls.coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
        cls.telemetry = read("lara/views/app/CoreSetHomeTelemetrySource.swift")
        cls.menu = read("lara/views/app/CoreSetMenuViewController.swift")
        cls.host = read("lara/overlay/CoreSetHUDHost.mm")

    def test_periodic_refresh_is_lightweight_and_input_safe(self):
        require_responsive_contract(self.coordinator, self.telemetry, self.menu)
        self.assertIn('"main-lifecycle-expired"', self.host)
        self.assertIn("kExpirationInterval", self.host)

    def test_negative_mutants_fail_contract(self):
        mutants = (
            (self.coordinator.replace("repeating: .milliseconds(500)", "repeating: .milliseconds(250)", 1), self.telemetry, self.menu),
            (self.coordinator.replace("self.refreshPeriodicObservations()", "self.publishStatus()", 1), self.telemetry, self.menu),
            (self.coordinator, self.telemetry.replace("producerLogSignatures[field] != logSignature", "true", 1), self.menu),
            (self.coordinator, self.telemetry, self.menu.replace("hostedDispatchControlID != nil", "false", 1)),
        )
        for coordinator, telemetry, menu in mutants:
            with self.assertRaises(AssertionError):
                require_responsive_contract(coordinator, telemetry, menu)

    def test_visual_contract_literals_unchanged_by_scheduler(self):
        rebuild = body(self.menu, "private func rebuildMenu(")
        for marker in ('label("CORE SET", size: 36', "CGRect(x: 170, y: 38, width: 658, height: 492)",
                       "panel.backgroundColor = gray(26, 250)", "closeButton.setTitleColor(gray(255, 80)"):
            self.assertIn(marker, rebuild)


if __name__ == "__main__":
    unittest.main()
