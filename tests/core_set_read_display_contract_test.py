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


def require_yaw_reread(source: str) -> None:
    for stable in ("includeWarningYaw && !CoreSet::warningYawRawValid(warningYawRaw)",
                   "actor + 0x190, &warningFallbackRaw)) return nil",
                   "actor.warningFallbackObserved", "warningFallbackRaw != actor.warningFallbackRaw",
                   "warningActorClass != actor.warningActorClass", "warningYawRaw != actor.warningYawRaw"):
        assert stable in source, stable


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
        for gate in ("settings.ignoreBots == true && mark.bot", "mark.warningYawDegrees",
                     "mark.distanceUnitsDividedBy100 <= Double(range)", "CoreSetWarningAngleMatches",
                     "CoreSetReferenceWarningText", "fontSize: CGFloat(textSize)"):
            self.assertIn(gate, warning)
        self.assertNotIn(".sorted", warning)
        self.assertNotIn("被瞄预警", warning)
        for reference in ('weaponID >= 1 && weaponID <= 9999999', '"未知玩家"', '"人机"',
                          '" 使用 未知武器("', '" 正在瞄准您"', 'std::to_string(meters) + "m"'):
            self.assertIn(reference, self.helper)

    def test_warning_fallback_owner_selection_and_raw_reread_fail_closed(self) -> None:
        require_yaw_reread(self.collector)
        self.assertLess(self.collector.index("CSClassIsChildOf(session, generation, actor, wanted"),
                        self.collector.index("actor + 0x190, &warningFallbackRaw"))
        for missing in ("warningFallbackRaw != actor.warningFallbackRaw",
                        "warningActorClass != actor.warningActorClass", "warningYawRaw != actor.warningYawRaw"):
            with self.subTest(missing=missing), self.assertRaises(AssertionError):
                require_yaw_reread(self.collector.replace(missing, "REMOVED"))
        header = read("lara/overlay/CoreSetPlayerSnapshot.h")
        self.assertIn("CoreSetWarningYawSourceReplicatedMovement = 2", header)
        self.assertIn("Neither source proves current controller aim", header)
        selection = read("lara/overlay/CoreSetWarningProjection.h")
        for checked in ("if (!warningYawRawValid(primary, &value))", "!fallbackPresent",
                        "!warningYawRawValid(fallback, &value)", "std::fmod(double(value) + 180.0, 360.0)"):
            self.assertIn(checked, selection)

    def test_unproven_fields_stay_diagnostic_not_read_offsets(self) -> None:
        for status in ("grenadeTimer=target-server-clock-clamped", "grenadeRadius=unproven", "grenadeAnimation=unproven",
                       "warningFallbackOwner=actor-replicated-movement-rotation-yaw", "informationLayout=local-subset",
                       "countScope=positive-health-or-last-breath-enemy-draw-range", "countParity=partial"):
            self.assertIn(status, self.collector)
        for guessed in ("actor + 0x258", "actor.address + 0x258", "ExplosionTime - Children"):
            self.assertNotIn(guessed, self.collector)
        self.assertIn("maximum <= 0 || health < 0 || health > maximum", self.collector)
        self.assertIn("if (health == 0 && !countEligible) continue", self.collector)
        self.assertLess(self.collector.index("distance > maximumDrawDistance"), self.collector.index("++observedBotCount"))
        self.assertLess(self.collector.index("++observedBotCount"), self.collector.index("bool onScreen ="))

    def test_zero_health_extension_is_count_only_and_has_lifecycle_reread(self) -> None:
        for scoped in ("CoreSet::playerCountEligible(health, maximum, countStatus)",
                       "status != count.status", "type != count.type", "zeroHealthLastBreath=%lu",
                       "if (health == 0) continue; // Count-only"):
            self.assertIn(scoped, self.collector)
        self.assertLess(self.collector.index("if (health == 0) continue; // Count-only"),
                        self.collector.index("CoreSetPlayerMark *mark ="))
        count = read("lara/overlay/CoreSetPlayerCount.h")
        for scoped in ("health < 0", "status >= 4", "health > 0 || status == 1"):
            self.assertIn(scoped, count)

    def test_ray_geometry_uses_verified_native_scale_and_top_anchor(self) -> None:
        render = body(self.player, "private func render(")
        self.assertIn("CoreSetReferencePlayerRay(size, Double(UIScreen.main.nativeScale), head,", render)
        self.assertNotIn("origin: CGPoint(x: size.width / 2, y: size.height)", render)
        projection = read("lara/overlay/CoreSetPlayerProjection.h")
        ray = body(projection, "inline bool referencePlayerRay(")
        for conversion in ("10.0 / nativeScale", "width / 2.0", "head.y - 30.0", "nativeScale <= 0"):
            self.assertIn(conversion, ray)
        self.assertIn("CoreSet::referencePlayerRay", self.collector)

    def test_grenade_clock_is_type_world_implementation_bound_and_reread(self) -> None:
        clock = body(self.collector, "static bool CSReadGrenadeClock(")
        for gate in ("CSClassIsChildOf", "clock->outer != level", "levelWorld != world",
                     "clock->getter != base + CSServerClockImplementationRVA",
                     "world + 0x15b0", "clock->gameState + 0x600", "std::isfinite(clock->worldTime)"):
            self.assertIn(gate, clock)
        self.assertNotIn("reinterpret_cast", clock)
        for stable in ("type != grenade.type", "outer != grenade.outer", "flags != grenade.flags",
                       "explosionRaw != grenade.explosionRaw", "eliteClassAfter != eliteProjectileClass",
                       "gameStateClassAfter != gameStateClass", "after.getter != grenadeClock.getter",
                       "after.worldTime < grenadeClock.worldTime", "after.worldTime - grenadeClock.worldTime > 0.25",
                       "std::memcmp(&after.delta, &grenadeClock.delta", "grenadeClockStatus=%u"):
            self.assertIn(stable, self.collector)
        render = body(self.player, "private func render(")
        self.assertIn("mark.countdownSeconds?.doubleValue", render)
        self.assertIn("timer.isFinite, timer > 0, timer <= 10", render)

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
                      "target_clock_owner_closed_reference_258_is_children_num", "owner_rep_movement_rotation_yaw_closed",
                      "children_num_eq1_proxy_not_gameplay_state", "not_verified"):
            self.assertIn(bound, probe)
        self.assertNotIn("write_text", probe)
        self.assertNotIn("write_bytes", probe)


if __name__ == "__main__":
    unittest.main(verbosity=2)
