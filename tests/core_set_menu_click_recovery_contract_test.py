"""Regression guards for logged menu failures; source audit, not UIKit execution."""
from pathlib import Path
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def body(source, signature):
    opening = source.index("{", source.index(signature))
    depth = 1
    for index in range(opening + 1, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[opening + 1:index]
    raise AssertionError(signature)


def local_apply_contract(source, channel, rebuild, observation):
    configured = body(source, "private func configureLocalConsumers()")
    start = configured.index(f"{channel}Consumer = CoreSetMenuConsumer(")
    end = configured.index(f"{channel}Channel = CoreSetFeatureChannel", start)
    apply = configured[start:end]
    deferred = apply.index("DispatchQueue.main.async")
    current = apply.index(f"self.{channel}Channel?.pendingApply?.token == request.token")
    suspended = apply.index(f"self.{channel}Channel?.suspended == false")
    idle = apply.index("self.hostedPointerID == nil, self.hostedDispatchControlID == nil")
    slider = apply.index("self.trackingUIKitSlider == nil")
    changed = apply.index(rebuild)
    observed = apply.index(observation)
    receipt = apply.index(".applied(observed: observed)")
    assert deferred < current < suspended < idle < slider < changed < observed < receipt
    assert "Local menu input is still tracking" in apply
    assert ".notApplied(reason:" in apply
    assert ".failed(reason:" in apply  # A mismatch must never become a success receipt.


class MenuClickRecoveryContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        read = lambda name: (ROOT / name).read_text(encoding="utf-8")
        cls.menu = read("lara/views/app/CoreSetMenuViewController.swift")
        cls.coordinator = read("lara/views/app/CoreSetRuntimeCoordinator.swift")
        cls.radar = read("lara/views/app/CoreSetRadarConsumer.swift")

    def test_local_receipts_wait_for_input_and_current_request(self):
        for channel, rebuild, observe in (
            ("appearance", "self.rebuildMenu()", "self.observeAppearance()"),
            ("directory", "self.rebuildCurrentPage()", "self.observeDirectory()"),
        ):
            with self.subTest(channel=channel):
                local_apply_contract(self.menu, channel, rebuild, observe)

    def test_stale_or_synchronous_local_apply_mutants_are_rejected(self):
        for old, new in (
            ("DispatchQueue.main.async { [weak self] in\n                guard let self, self.selectedPage", "do {\n                guard let self, self.selectedPage"),
            ("self.directoryChannel?.pendingApply?.token == request.token", "true"),
            ("self.directoryChannel?.suspended == false", "true"),
            ("self.hostedPointerID == nil, self.hostedDispatchControlID == nil", "true"),
        ):
            with self.subTest(mutation=old):
                self.assertIn(old, self.menu)
                with self.assertRaises((AssertionError, ValueError)):
                    local_apply_contract(self.menu.replace(old, new), "directory",
                                         "self.rebuildCurrentPage()", "self.observeDirectory()")

    def test_brand_readback_matches_drawn_labels_and_directory_depth(self):
        brand = body(self.menu, "private func addReferenceBrand(")
        observe = body(self.menu, "private func observeAppearance()")
        for label in ('label("C",', 'label("ORE",', 'label("SET",'):
            self.assertIn(label, brand)
        self.assertIn('$0.text == "C"', observe)
        self.assertIn("brand.textColor", observe)
        self.assertIn("brandParts.allSatisfy", observe)
        self.assertNotIn('attributedText?.string == "CORE SET"', observe)
        card = body(self.menu, "private func card(")
        self.assertIn("pageViews.append(result)", card)
        self.assertIn("result.addSubview(body)", card)
        self.assertIn("return body", card)
        self.assertIn("card.addSubview(button)", body(self.menu, "private func categoryTabs("))
        self.assertIn("pageViews.flatMap({ $0.subviews }).flatMap({ $0.subviews })",
                      body(self.menu, "private func observeDirectory()"))

    def test_valid_remote_host_retains_channels_but_local_teardown_still_stops(self):
        deactivate = body(self.coordinator, "func deactivate()")
        retained = deactivate[:deactivate.index("aimSuspendedForHost = true")]
        for gate in ("guard !stopping, !applicationDeactivated", "remoteHostingAdapter != nil",
                     "!returnToLocalPending", "!exitHUDRestorationPending", "!remoteCleanupFailed"):
            self.assertIn(gate, retained)
        self.assertIn("host.setApplicationActive(false)", retained)
        self.assertIn("deactivate-remote-retained", retained)
        self.assertIn("return", retained)
        self.assertNotIn("suspendActionConsumers", retained)
        self.assertIn("menu.suspendActionConsumers", deactivate)
        self.assertLess(deactivate.index("applicationDeactivated = true"),
                        deactivate.index("host.setApplicationActive(false)"))
        self.assertIn("applicationDeactivated = false", body(self.coordinator, "func activate()"))
        self.assertIn("suspendActionConsumers", body(self.coordinator, "private func rebuildHostedWindows("))
        host_changed = body(self.coordinator, "private func hostChanged()")
        self.assertIn("!retainActionsForRemoteInactive", host_changed)
        self.assertIn("suspendActionConsumers", host_changed)
        retention = body(self.coordinator, "private var retainActionsForRemoteInactive:")
        for gate in ("applicationDeactivated", "remoteHostingAdapter != nil", "!returnToLocalPending",
                     "!exitHUDRestorationPending", "!remoteCleanupFailed"):
            self.assertIn(gate, retention)

    def test_host_visibility_is_owned_snapshot_replay_not_generic_feature_channel(self):
        self.assertIn("protocol CoreSetMenuHostPresentationOwner: AnyObject", self.menu)
        self.assertNotIn("hostChannel", self.menu)
        start = self.menu.index("func requestMenuVisibility(")
        request = self.menu[start:self.menu.index("func stopMenuHostPresentation", start)]
        self.assertIn("desiredHostPresentation.menuVisible = visible", request)
        self.assertIn("applyHostSettings", request)
        changed = body(self.coordinator, "private func hostChanged()")
        self.assertIn("menu.reconcileMenuHostPresentation", changed)
        toggle = body(self.coordinator, "private func requestVisibility(")
        self.assertIn("panel-request-receipt", toggle)
        launch = body(self.coordinator, "private func showHostedMenuAndOpenGame(")
        self.assertIn("requestMenuVisibility(true)", launch)
        self.assertNotIn("guard confirmed else", launch)
        self.assertLess(launch.index("requestMenuVisibility(true)"),
                        launch.index("CoreSetGameTarget.openApplication"))

    def test_category_navigation_is_local_even_when_directory_receipts_are_unavailable(self):
        tabs = body(self.menu, "private func categoryTabs(")
        select = body(self.menu, "@objc private func selectMaterialCategory(")
        self.assertIn("button.isEnabled = true", tabs)
        self.assertNotIn("localDirectoryReady", tabs + select)
        self.assertNotIn("applyLocalDirectory", select)
        self.assertNotIn("prepareApply", select)
        self.assertIn("previewMaterialCategory = category", select)
        self.assertIn("materialGrid.contentOffset = .zero", select)
        self.assertIn("DispatchQueue.main.async", select)
        self.assertIn("self.previewMaterialCategory == category", select)
        self.assertIn("self.rebuildCurrentPage()", select)

    def test_radar_switches_edit_before_complete_parameters_but_apply_stays_validated(self):
        rows = body(self.menu, "private func disabledRows(")
        radar = rows[rows.index('title == "雷达" ||'):rows.index('title == "被瞄预警" ||')]
        warning = rows[rows.index('title == "被瞄预警" ||'):]
        for controls in (radar, warning):
            self.assertIn("controlAvailability(field, in: featureState.radar) == .ready", controls)
            self.assertIn("button.isEnabled = ready", controls)
            self.assertNotIn("|| configured", controls)
        for signature in ("@objc private func toggleRadarField(", "@objc private func toggleWarningField("):
            handler = body(self.menu, signature)
            self.assertIn("controlAvailability(field, in: featureState.radar) == .ready", handler)
            self.assertIn(r"editGame(\.radar)", handler)
            self.assertNotIn("if enabling &&", handler)
        accepts = body(self.radar, "private func accepts(")
        for parameter in ("state.warningRange.value == nil", "state.warningTextSize.value == nil",
                          "state.detectionDistance.value != nil", "state.placement.radius != nil",
                          "state.placement.x != nil", "state.placement.y != nil"):
            self.assertIn(parameter, accepts)
        apply = body(self.radar, "func apply(")
        self.assertLess(apply.index("accepts(request.desired)"), apply.index("revision += 1"))
        self.assertLess(apply.index(".notApplied(reason:"), apply.index("revision += 1"))

    def test_reference_ipa_replays_core_static_addresses(self):
        reference = ROOT.parent / "源码 - 和平" / "自签Core-SET和平-v1.7.ipa"
        if not reference.is_file():
            self.skipTest("Core v1.7 sample unavailable; native-address replay was not run")
        sys.path.insert(0, str(ROOT / "tools"))
        from core_set_v17_function_chain_probe import CoreImage, IPA_SHA, IMAGE_SHA
        from core_set_v17_home_producer_probe import selector_stub
        fixture = json.loads((ROOT / "tests/fixtures/core_set_v17_click_behavior.json").read_text(encoding="utf-8"))
        self.assertFalse(fixture["runtime_verified"])
        self.assertEqual(fixture["ipa_sha256"], IPA_SHA)
        self.assertEqual(fixture["image_sha256"], IMAGE_SHA)
        core = CoreImage(reference)
        for address, expected_bytes, expected_instruction in fixture["instructions"]:
            with self.subTest(address=address):
                native = core.instructions(int(address, 16), 4)[0]
                self.assertEqual(native.bytes.hex(), expected_bytes)
                self.assertEqual((native.mnemonic + " " + native.op_str).strip(), expected_instruction)
        self.assertEqual(selector_stub(core, 0x1007309C0)["selector"], "setQp476:")
        self.assertEqual(selector_stub(core, 0x10072FC00)["selector"], "setInteger:forKey:")
        for address, text in fixture["brand_strings"]:
            self.assertEqual(core.string(int(address, 16)), text)


if __name__ == "__main__":
    unittest.main()
