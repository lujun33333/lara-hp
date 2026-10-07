"""Source contracts for staging versus observed application; no device claim."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "lara/views/app"
EXPECTED = {
    "Player": {
        f"actor:{scope}:{field}"
        for scope in ("player", "bot")
        for field in ("weapon", "count", "information", "ray", "box", "distance", "bones")
    } | {"hideBots", "grenadeWarning", "backIndicator", "backStyle", "drawingDistance", "boneDistance", "backSize"},
    "Material": {"materialEnabled", "hideWhileArmed", "metroArmor", "hideOpenedCrates",
                 "showCrateLevel", "vehicleStatus", "materialDistance", "materialColor", "materialGroupSelection"},
    "Adjustment": {
        f"actorColor:{scope}:{field}"
        for scope in ("player", "bot")
        for field in ("name", "ray", "distance", "bone", "team")
    } | {"rayThickness", "boneThickness", "materialFontSize"},
    "Radar": {"radarEnabled", "radarShowDistance", "radarDetectionDistance", "radarRadius", "radarX", "radarY",
              "warningEnabled", "warningIgnoreBots", "warningRange", "warningTextSize"},
    "FrameRate": {"framesPerSecond"},
    "AimDisplay": {"localAimCircle", "localAimCircleSize", "localAimPreviewLine", "localAimPreviewMarker",
                   "localAimDynamicCircle", "localAimPreviewBots", "localAimPreviewDistance"},
}


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:position]
    raise AssertionError(f"unterminated body: {signature}")


def configured_fields(source: str) -> set[str]:
    configured = body(source, "var configurableFields:")
    assert not re.search(r"\b(?:availability|ready|session|coordinator|preview)\b", configured), \
        "staged configuration must not disappear while its runtime producer is unavailable"
    fields: set[str] = set()

    def compound(match: re.Match[str]) -> str:
        fields.add(":".join(match.groups()))
        return ""

    configured = re.sub(r"\.(actorColor|actor)\(\.(\w+),\s*\.(\w+)\)", compound, configured)
    fields.update(re.findall(r"\.(\w+)", configured))
    return fields


def require_live_apply(source: str) -> None:
    apply = body(source, "func apply(")
    assert "availability == .ready" in apply, "staging must not bypass live application readiness"
    assert ".notApplied(reason:" in apply, "a pre-submit rejection must explicitly preserve retryability"


class ConsumerConfigurationContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.sources = {
            name: (APP / f"CoreSet{name}Consumer.swift").read_text(encoding="utf-8")
            for name in EXPECTED
        }

    def test_inventory_61_fields_can_be_staged(self) -> None:
        all_fields: set[str] = set()
        for name, expected in EXPECTED.items():
            with self.subTest(consumer=name):
                actual = configured_fields(self.sources[name])
                self.assertEqual(actual, expected)
                self.assertTrue(all_fields.isdisjoint(actual))
                all_fields.update(actual)
        self.assertEqual(len(all_fields), 61)

    def test_live_support_and_application_remain_gated(self) -> None:
        for name, source in self.sources.items():
            with self.subTest(consumer=name):
                supported = body(source, "var supportedFields:")
                self.assertIn("availability == .ready", supported)
                require_live_apply(source)
        adjustment = body(self.sources["Adjustment"], "var supportedFields:")
        self.assertIn("playerStyleReady == true", adjustment)
        self.assertIn("materialStyleReady == true", adjustment)
        preview = body(self.sources["AimDisplay"], "var supportedFields:")
        self.assertIn("if preview.ready", preview)

    def test_canvas_and_exact_receipts_are_required(self) -> None:
        for name in ("Player", "Material", "Radar", "Adjustment", "AimDisplay"):
            with self.subTest(consumer=name):
                source = self.sources[name]
                self.assertIn("coordinator?.playerCanvas != nil", body(source, "var availability:"))
                self.assertNotIn(".applied(observed:", body(source, "func apply("))
                receipt = body(source, "func consumed(")
                for identity in ("receipt.configRevision == revision", "receipt.snapshotID == expectedSnapshot",
                                 "receipt.hostGeneration == expectedGeneration", "receipt.requestToken",
                                 "receipt.acceptedByLocalRenderer"):
                    self.assertIn(identity, receipt)
                self.assertIn(".applied(observed:", receipt)
        for name in ("Player", "Material", "Radar"):
            receipt = body(self.sources[name], "func consumed(")
            for identity in ("session.ready", "session.generation == expectedSessionGeneration",
                             "session.processID == expectedProcessID", "session.imageBase == expectedImageBase"):
                self.assertIn(identity, receipt)
        radar = body(self.sources["Radar"], "func consumed(")
        self.assertIn("confirmedLanes == ownedLanes", radar)
        self.assertIn("coordinator?.applyFrameRate(value) == true", body(self.sources["FrameRate"], "func apply("))

    def test_metro_armor_alone_keeps_refreshing(self) -> None:
        receipt = body(self.sources["Material"], "func consumed(")
        self.assertRegex(receipt, r"if settings\.enabled == true \|\| settings\.metroArmor == true\s*\{\s*refresh = Timer")

    def test_target_writers_remain_unconfigurable(self) -> None:
        for name in ("Aim", "Recoil"):
            source = (APP / f"CoreSet{name}Consumer.swift").read_text(encoding="utf-8")
            self.assertNotIn("var configurableFields:", source)
            self.assertRegex(body(source, "var supportedFields:"), r"^\s*\[\]\s*$")
            self.assertNotIn(".applied(observed:", body(source, "func apply("))

    def test_contract_rejects_ready_dependent_configuration_and_unchecked_apply(self) -> None:
        player = self.sources["Player"]
        blocked = player.replace("var configurableFields: Set<CoreSetField> {",
                                 "var configurableFields: Set<CoreSetField> {\n        guard availability == .ready else { return [] }")
        with self.assertRaisesRegex(AssertionError, "staged configuration"):
            configured_fields(blocked)
        unchecked = player.replace("availability == .ready, accepts(request.desired)", "accepts(request.desired)")
        with self.assertRaisesRegex(AssertionError, "live application readiness"):
            require_live_apply(unchecked)


if __name__ == "__main__":
    unittest.main(verbosity=2)
