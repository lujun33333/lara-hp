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
                   "actor + 0x190, &warningFallbackRaw)) continue",
                   "actor.warningFallbackObserved", "actor.address + 0x190,",
                   "actorClassAfter != actor.warningActorClass", "actor.address + 0x2758, &warningYawRaw"):
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
                       "actor.address + 0x2758, &warningYawRaw"):
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
        self.assertLess(self.collector.index("CSClassTypeIsChildOf(session, generation, actorClass, wanted"),
                        self.collector.index("actor + 0x190, &warningFallbackRaw"))
        for missing in ("actor.address + 0x190,",
                        "actorClassAfter != actor.warningActorClass", "actor.address + 0x2758, &warningYawRaw"):
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
        for status in ("grenadeTimer=target-server-clock-clamped", "grenadeRadius=unproven", "grenadeAnimation=local-prediction-partial",
                       "warningFallbackOwner=actor-replicated-movement-rotation-yaw", "informationLayout=local-subset",
                       "countScope=positive-health-or-last-breath-enemy-draw-range", "countParity=partial"):
            self.assertIn(status, self.collector)
        for guessed in ("actor + 0x258", "actor.address + 0x258", "ExplosionTime - Children"):
            self.assertNotIn(guessed, self.collector)
        self.assertIn("maximum <= 0 || health < 0 || health > maximum", self.collector)
        self.assertIn("if (health == 0 && !countEligible) continue", self.collector)
        self.assertLess(self.collector.index("distance > maximumDrawDistance"), self.collector.index("++observedBotCount"))
        self.assertLess(self.collector.index("++observedBotCount"), self.collector.index("bool onScreen ="))

    def test_optional_grenade_and_bone_failures_do_not_poison_player_frame(self) -> None:
        for token in ("const bool nameIndexReady", "if (nameIndexReady)",
                      "collectGrenades = false", "invalidGrenadeMarks",
                      "observedBones.size() < CSMaxBoneActors"):
            self.assertIn(token, self.collector)
        self.assertNotIn("grenadeMarks.count >= 256) return nil", self.collector)
        self.assertNotIn("observedBones.size() >= CSMaxBoneActors) return nil", self.collector)
        optional_roots = self.collector[self.collector.index('CSLastCaptureDiagnostic = "stability-optional-roots"'):
                                        self.collector.index('CSLastCaptureDiagnostic = "stability-actor-membership"')]
        self.assertIn("collectGrenades = false", optional_roots)
        self.assertNotIn("return nil", optional_roots)

    def test_actor_array_matches_core17_data_count_and_level_fallback(self) -> None:
        helper = body(self.collector, "static CSActorArraySource CSReadCoreActorArray(")
        for token in ("level + 0xe0", "primaryContainer + 0x28", "primaryContainer + 0x30",
                      "level + 0xa0", "level + 0xa8", "CSActorArraySource::primary",
                      "CSActorArraySource::levelFallback", "CSActorArraySpanValid"):
            self.assertIn(token, helper)
        self.assertNotIn("primaryContainer + 0x34", helper)
        self.assertIn("array->capacity = count", helper)
        self.assertLess(helper.index("primaryContainer + 0x28"), helper.index("level + 0xa0"))
        span = body(self.collector, "static bool CSActorArraySpanValid(")
        self.assertIn("count > 0 && count < CSMaxActors", span)
        self.assertIn("data & (alignof(uint64_t) - 1)", span)
        for diagnostic in ("root-actor-array-core17-fallback-read-failed",
                           "root-actor-array-core17-fallback-count-invalid",
                           "root-actor-array-core17-fallback-data-invalid",
                           "stability-actor-array-core17-fallback-read-failed",
                           "stability-actor-array-core17-fallback-count-invalid",
                           "stability-actor-array-core17-fallback-data-invalid",
                           "stability-actor-array-core17-unavailable"):
            self.assertIn(diagnostic, self.collector)
        self.assertIn("std::strcmp(actorArrayFailureAfter", self.collector)
        for stable in ("actorArraySourceAfter != actorArraySource",
                       "clusterAfter != cluster", "arrayAfter.data != array.data"):
            self.assertIn(stable, self.collector)
        self.assertIn("actorArraySource=%s", self.collector)

    def test_actor_scan_uses_core17_batch_fallback_and_class_cache(self) -> None:
        for token in ("CSActorPointerBatch = 0x200", "std::vector<uint64_t> pointers(CSActorPointerBatch)",
                      "start += CSActorPointerBatch", "pointers.data()", "CSReadValue(session, generation,",
                      "characterClassCache.find(actorClass)", "grenadeClassCache.find(grenadeClass)",
                      "CSClassTypeIsChildOf"):
            self.assertIn(token, self.collector)
        scan = self.collector[self.collector.index("for (int32_t start = 0; start < array.count;"):
                              self.collector.index('CSLastCaptureDiagnostic = "stability-roots"')]
        self.assertLess(scan.index("pointers.data()"),
                        scan.index("for (int32_t index = 0; index < batch; ++index)"))
        self.assertIn("array.data + (uint64_t)(start + index) * 8", scan)
        self.assertNotIn("captureBudgetExceeded", scan)
        self.assertNotIn("capture-budget-exceeded", scan)

    def test_zero_health_extension_is_count_only_and_has_lifecycle_reread(self) -> None:
        for scoped in ("CoreSet::playerCountEligible(health, maximum, countStatus)",
                       "count.address + 0x3be0, &status", "type != count.type", "zeroHealthLastBreath=%lu",
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
        for stable in ("type != grenade.type", "outer != grenade.outer", "!(flags & 8) || (flags & 4)",
                       "grenade.explosionRaw = explosionRaw", "eliteClassAfter == eliteProjectileClass",
                       "gameStateClassAfter == gameStateClass", "after.getter == grenadeClock.getter",
                       "after.worldTime >= grenadeClock.worldTime", "after.worldTime - grenadeClock.worldTime <= 0.45",
                       "invalidGrenadeMarks", "grenadeClockStatus=%u"):
            self.assertIn(stable, self.collector)
        render = body(self.player, "private func render(")
        self.assertIn("mark.countdownSeconds?.doubleValue", render)
        self.assertIn("timer.isFinite, timer > 0, timer <= 10", render)

    def test_bone_head_is_known_profile_requested_capture_and_end_reread(self) -> None:
        head = body(self.collector, "static bool CSProjectBoneHead(")
        self.assertIn("CoreSet::referenceBoneHeadIndex", head)
        self.assertIn("sample == state.samples.end()", head)
        self.assertIn("CoreSet::transformPoint", head)
        self.assertIn("point->y <= size.height", head)
        bones = body(self.collector, "static bool CSReadBoneState(")
        for gate in ("state->registered & 4", "state->flags", "state->callback != base + CSPositionCallbackRVA",
                     "CoreSet::decodePositionBlock", "array.count > 256", "state->edges[edge] >= array.count"):
            self.assertIn(gate, bones)
        for stable in ("left.registered == right.registered", "left.flags == right.flags",
                       "left.callback == right.callback", "left.key == right.key", "CSBoneStructureEqual(bone.state, after)"):
            self.assertIn(stable, self.collector)
        self.assertIn("mark.head = top; mark.headBoneIndex = @(headIndex)", self.collector)
        self.assertIn("headScope=requested-bones-only headParity=partial", self.collector)

    def test_local_grenade_motion_is_bounded_and_only_after_current_snapshot_gates(self) -> None:
        tracker = read("lara/overlay/CoreSetGrenadeMotion.h")
        for gate in ("maximumEntries = 256", "now <= frameTime_", "now <= entry.lastSeen",
                     "!(context == context_)", "now - entry.firstSeen > 2", "interval >= 0.004 && interval <= 1",
                     "speed >= 30000", "now - entry.sampleTime > 0.35", "speed <= 25", "step > 28"):
            self.assertIn(gate, tracker)
        decorate = body(self.collector, "- (void)decorateSnapshot:")
        for gate in ("NSThread.isMainThread", "if (!mark.countdownSeconds) continue", "projected >= 64",
                     "snapshot.sessionGeneration", "snapshot.imageBase", "snapshot.processID",
                     "mark.motionType", "mark.motionNameIndex", "mark.motionExplosionRaw",
                     "CoreSet::referenceGrenadePrediction", "motionCircle=screen-pixels-not-blast-radius"):
            self.assertIn(gate, decorate)
        for target_read in ("CSRead", "session readAt", "CSPosition", "CSReadValue"):
            self.assertNotIn(target_read, decorate)
        capture = body(self.player, "private func capture(")
        self.assertLess(capture.index("snapshot.sessionGeneration == self.session.generation"),
                        capture.index("self.grenadeMotion.decorate"))
        self.assertLess(capture.index("self.activeToken == token, self.revision == expectedRevision"),
                        capture.index("self.grenadeMotion.decorate"))
        self.assertIn("grenadeMotion.clear()", body(self.player, "private func clearStaleLane("))
        shutdown = body(self.player, "func shutdownReadSession()")
        self.assertIn("let motionClean = grenadeMotion.clear()", shutdown)
        self.assertIn("motionClean && cleanup.complete", shutdown)
        render = body(self.player, "private func render(")
        self.assertIn("for segment in mark.predictionSegments", render)
        self.assertIn("if mark.predictionEndpointPresent", render)

    def test_sync_opened_is_typed_end_reread_observation_not_reference_filter(self) -> None:
        for gate in ("CSMInteractiveTreasureBoxClassSlot = 0x11b81f80", "actor + 0x5fd, &openedSync",
                     "if (typed)", "openedSync > 1", "openedSyncAfter != item.openedSync",
                     "openedClassAfter != openedClass", "openedProxyDisagree=%lu"):
            self.assertIn(gate, self.material_collector)
        self.assertIn("Not substituted for Core's Children.Num==1 filter", read("lara/overlay/CoreSetMaterialSnapshot.h"))
        render = body(self.material, "private func render(")
        self.assertIn("mark.escapeBoxChildrenCount?.intValue == 1", render)
        self.assertNotIn("interactiveTreasureBoxSyncOpened", render)
        for uncertain in ("networkFreshness=unproven", "informationGap=native-font-icons-and-anchors",
                          "grenadeRadiusGap=no-verified-elite-blast-field"):
            self.assertIn(uncertain, self.collector)

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
