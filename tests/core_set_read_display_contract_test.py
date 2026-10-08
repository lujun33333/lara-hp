"""Read-only display semantics and lifecycle contracts; not iOS/device validation."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def body(source: str, signature: str) -> str:
    opening = source.index("{", source.index(signature))
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{":
            depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:position]
    raise AssertionError(f"unterminated {signature}")


def require_receipt_gates(source: str) -> None:
    receipt = body(source, "func consumed(")
    for gate in ("receipt.requestToken", "receipt.configRevision == revision",
                 "receipt.snapshotID == expectedSnapshot", "receipt.hostGeneration == expectedGeneration",
                 "receipt.acceptedByLocalRenderer", "session.generation == expectedSessionGeneration",
                 "session.processID == expectedProcessID", "session.imageBase == expectedImageBase",
                 "guard identityMatches && fresh else", "snapshot-stale stage=receipt"):
        assert gate in receipt, gate
    assert "logReadSemanticReceipt(receipt)" in receipt
    assert ".applied(observed:" not in body(source, "func apply(")


class ReadDisplayContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.player = read("lara/views/app/CoreSetPlayerConsumer.swift")
        cls.material = read("lara/views/app/CoreSetMaterialConsumer.swift")
        cls.radar = read("lara/views/app/CoreSetRadarConsumer.swift")
        cls.collector = read("lara/overlay/CoreSetPlayerSnapshot.mm")
        cls.material_collector = read("lara/overlay/CoreSetMaterialSnapshot.mm")
        cls.helper = read("lara/overlay/CoreSetReadDisplaySemantics.h")

    def test_numeric_conversion_is_bounded_and_production_uses_helper(self) -> None:
        numeric = body(self.helper, "inline bool displayDistanceMeters(")
        for gate in ("*output = 0", "std::isfinite(distance)", "distance < 0",
                     "std::numeric_limits<int32_t>::max()", "std::round(distance)", "std::trunc(distance)"):
            self.assertIn(gate, numeric)
        render = body(self.player, "private func render(")
        self.assertIn("CoreSetReferencePlayerDistanceText(mark.distanceUnitsDividedBy100)", render)
        self.assertNotIn('String(format: "%.0f",', render)
        self.assertIn('std::to_string(meters) + " 米"', self.helper)
        self.assertIn('CoreSet::referencePlayerDistanceText(distance)', self.collector)
        self.assertIn('CoreSet::referenceWarningText(playerName.UTF8String', self.collector)

    def test_warning_name_weapon_reads_only_when_enabled_and_rereads(self) -> None:
        capture = body(self.radar, "private func capture(")
        for requested in ("let includeWarningYaw = settings.warningEnabled == true",
                          "playerWeaponText: includeWarningYaw, botWeaponText: includeWarningYaw",
                          "playerInformation: includeWarningYaw, botInformation: includeWarningYaw"):
            self.assertIn(requested, capture)
        for stable in ("actor.weaponObserved", "weapon != actor.weapon || weaponID != actor.weaponID",
                       "actor.nameObserved", "namePointer != actor.namePointer || nameRaw != actor.nameRaw",
                       "warningYawRaw != actor.warningYawRaw"):
            self.assertIn(stable, self.collector)

    def test_warning_order_unit_and_unknown_weapon_are_reference_branches(self) -> None:
        warning = body(self.radar, "private func renderWarning(")
        for gate in ("settings.ignoreBots == true && mark.bot", "mark.warningServerYawDegrees",
                     "mark.distanceUnitsDividedBy100 <= Double(range)", "CoreSetWarningAngleMatches",
                     "CoreSetReferenceWarningText", "fontSize: CGFloat(textSize)"):
            self.assertIn(gate, warning)
        self.assertNotIn(".sorted", warning)
        self.assertNotIn("被瞄预警", warning)
        for reference in ('weaponID >= 1 && weaponID <= 9999999', '"未知玩家"', '"人机"',
                          '" 使用 未知武器("', '" 正在瞄准您"', 'std::to_string(meters) + "m"'):
            self.assertIn(reference, self.helper)

    def test_unproven_fields_stay_diagnostic_not_read_offsets(self) -> None:
        for status in ("grenadeTimer=unproven", "grenadeRadius=unproven", "grenadeAnimation=unproven",
                       "warningFallback=unproven", "informationLayout=local-subset",
                       "countScope=positive-health-enemy-draw-range"):
            self.assertIn(status, self.collector)
        for guessed in ("actor + 0x190", "actor.address + 0x190", "actor + 0x88c", "ExplosionTime -"):
            self.assertNotIn(guessed, self.collector)
        self.assertIn("maximum <= 0 || health <= 0 || health > maximum", self.collector)
        self.assertLess(self.collector.index("distance > maximumDrawDistance"), self.collector.index("++observedBotCount"))
        self.assertLess(self.collector.index("++observedBotCount"), self.collector.index("bool onScreen ="))

    def test_material_scope_full_capture_clock_and_no_nil_percent_fabrication(self) -> None:
        render = body(self.material, "private func render(")
        for scoped in ("record.category == .crates", "mark.escapeBoxChildrenCount?.intValue == 1",
                       "record.category == .vehicles", 'Int(mark.distanceUnitsDividedBy100)',
                       "if let hp = mark.vehicleHPPercent, let fuel = mark.vehicleFuelPercent",
                       "if settings.metroArmor == true", "fontSize: 14"):
            self.assertIn(scoped, render)
        self.assertNotIn("vehicleHPPercent ??", render)
        metro = render[render.index("if settings.metroArmor == true"):]
        self.assertNotIn(".materialText", metro)
        self.assertIn("snapshot?.captureCompletedMonotonicSeconds", self.material)
        for scoped in ("openedRule=children-num-eq1-proxy gameplayOpened=unproven", "metroCharacters=",
                       "vehicleComponentTyped=", "childrenOne=", "levelsPresent="):
            self.assertIn(scoped, self.material_collector)
        self.assertLess(self.material_collector.index("for (const ObservedMetro &item"),
                        self.material_collector.index("snapshot.captureCompletedMonotonicSeconds"))

    def test_exact_receipts_and_throttled_no_sensitive_output(self) -> None:
        for source in (self.player, self.material, self.radar):
            require_receipt_gates(source)
            logger = body(source, "private func logReadSemanticReceipt(")
            for gate in ("lastSemanticLogRevision != receipt.configRevision", "now - lastSemanticLogAt >= 30",
                         "receipt.snapshotID.uuidString", "session.generation", "session.processID",
                         "evidence=local-renderer-frame parity=partial"):
                self.assertIn(gate, logger)
            for sensitive in ("playerName", "weaponName", "actorAddress", "imageBase"):
                self.assertNotIn(sensitive, logger)
            self.assertIn("expectedReadSemanticDiagnostic = nil", body(source, "func shutdownReadSession()"))
        radar_receipt = body(self.radar, "func consumed(")
        self.assertGreaterEqual(radar_receipt.count("if confirmedLanes == ownedLanes {"), 3)
        self.assertIn("confirmedLanes.removeAll() // Each frame", body(self.radar, "private func submit("))

    def test_negative_missing_identity_generation_full_length_and_scope_rejected(self) -> None:
        for removed in ("receipt.snapshotID == expectedSnapshot", "session.generation == expectedSessionGeneration",
                        "receipt.acceptedByLocalRenderer", "guard identityMatches && fresh else"):
            with self.subTest(removed=removed), self.assertRaises(AssertionError):
                require_receipt_gates(self.player.replace(removed, "REMOVED"))
        for source in (self.collector, self.material_collector):
            self.assertIn("completedBytes:&done", source)
            self.assertIn("done == length", source)
            self.assertIn("session.generation != generation", source)
            for extension in ("RemoteCall", "vmmapremotepage", "ds_kread", "task_for_pid(", "mach_vm_write"):
                self.assertNotIn(extension, source)

    def test_reference_probe_binds_both_samples_and_preserves_boundaries(self) -> None:
        probe = read("tests/core_set_read_display_reference_probe.py")
        for bound in ("actual == expected", "CORE_SHA", "TARGET_SHA", "property_at(target",
                      "instruction.mnemonic == mnemonic", "assert actual == expected",
                      "needs_same-owner_clock_and_lifecycle", "needs_owner_at_190",
                      "children_num_eq1_proxy_not_gameplay_state", "not_verified"):
            self.assertIn(bound, probe)
        self.assertNotIn("write_text", probe)
        self.assertNotIn("write_bytes", probe)


if __name__ == "__main__":
    unittest.main(verbosity=2)
