"""137 native point chains, function edges and optional exact-sample replay.

Fixture/source contracts are not native execution or game-effect verification.
Negative controls mutate only memory. --reference-ipa binds every captured word
and direct edge to the original sample without extracting or executing it.
"""

from __future__ import annotations

import argparse
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
POINT_PATH = ROOT / "tests/fixtures/core_set_v17_native_point_chain_map.json"
NATIVE_PATH = ROOT / "tests/fixtures/core_set_v17_native_function_slices.json"
POINTS = json.loads(POINT_PATH.read_text(encoding="utf-8"))
NATIVE = json.loads(NATIVE_PATH.read_text(encoding="utf-8"))
IPA_SHA = "57412d36a1092931d81a9a820c57eb5c1eb92dcf77076ce865dc95035a3a41cb"
IMAGE_SHA = "c842be92434b88b4d535d0d10a30ace068ce6b9a7b9a97ec5a6ca8fd97fa3dd5"
ALTERNATIVES = {108, 110, 111, 112, 113, 115, 117}


def validate(points: dict, native: dict) -> None:
    assert points["reference_ipa_sha256"] == native["ipa_sha256"] == IPA_SHA
    assert points["reference_image_sha256"] == native["image_sha256"] == IMAGE_SHA
    assert native["function_starts_present"] is False
    assert [point["id"] for point in points["points"]] == [f"v17-{index:03d}" for index in range(137)]
    windows = {window["address"] for window in native["proof_windows"]}
    assert len(windows) == len(native["proof_windows"]) == 159
    for index, point in enumerate(points["points"]):
        assert point["reference_evidence_key"] == "native-v17/" + point["id"]
        assert point["original_runtime_receipt_verified"] is False
        assert point["one_to_one_complete"] is False
        assert point["alternative_preview"] == (index in ALTERNATIVES)
        assert point["chain_profile"] in points["chain_profiles"]
        assert point["control_sites"] and set(point["control_sites"]) <= windows
        assert point["transform"] and len(point["stage_evidence"]) == 6
        assert point["unresolved_stages"] and point["next_probes"]
        for storage in point["storage"]:
            assert not storage["owner"].startswith("target")
            if "base" in storage:
                assert storage["owner"] == "Core-self-configuration"
                assert storage["base"] == "0x100c58270"
                assert 0 <= int(storage["offset"], 16) < 0x1D0
                assert storage["width"] in (1, 4, 16)
    for function in native["functions"].values():
        assert int(function["entry"], 16) < int(function["candidate_end"], 16)
        assert function["end_basis"] and not function["truncated"]
        assert all(not edge["instruction"].startswith("brk ")
                   for edge in function["unresolved_indirect_edges"])
    for profile in points["chain_profiles"].values():
        assert profile["stop"] and profile["receipt_limit"] and profile["device_probe"]
        for source, target, site, *kind in profile["exact_edges"]:
            owner = native["functions"][source]
            edges = owner["candidate_tail_calls"] if kind == ["tail"] else owner["inter_root_calls"]
            anchor = native["functions"][target]["requested_anchor"]
            assert any(edge["site"] == site and edge["callee"] == anchor for edge in edges), (source, target, site)
    assert points["points"][104]["storage"][0]["offset"] == "0x11c"
    assert points["points"][105]["storage"][0]["offset"] == "0x10c"
    assert "inverse" in points["points"][110]["transform"]
    assert "inverse" in points["points"][132]["transform"]
    assert points["points"][132]["storage"][0]["offset"] == "0x18d"
    assert native["configuration_tables"]["trigger_ui_to_storage"]["values"] == [1, 2, 0, 3]
    assert native["configuration_tables"]["scene_ui_to_storage"]["values"] == [0, 2, 1, 3]
    block = native["action_timer_block"]
    assert block["decoded_invoke"] == native["functions"]["action_worker"]["entry"] == "0x1000c1a04"
    assert block["registration_call"] == "0x1000c19d4"
    assert block["interval_nanoseconds"] == 16666666
    assert block["runtime_scheduling_verified"] is False
    assert native["read_transport_import"]["symbol"] == "_getsockopt"


class NativePointChainTests(unittest.TestCase):
    def test_all_points_and_stage_boundaries(self):
        validate(POINTS, NATIVE)

    def test_same_stable_ids_and_titles_as_current_menu(self):
        menu = json.loads((ROOT / "tests/fixtures/core_set_v17_menu_point_map.json").read_text(encoding="utf-8"))
        columns = {column: index for index, column in enumerate(menu["columns"])}
        for native, row in zip(POINTS["points"], menu["points"], strict=True):
            self.assertEqual((native["id"], native["page"], native["title"]),
                             tuple(row[columns[key]] for key in ("id", "page", "title")))

    def test_read_and_write_chains_not_interchanged(self):
        read = POINTS["chain_profiles"]["read-hud"]
        action = POINTS["chain_profiles"]["aim-recoil"]
        self.assertNotIn("checked_write", read["reader_path"])
        self.assertIn("read_socket_primitive", read["reader_path"])
        self.assertEqual(action["writer"], ["write_merge", "checked_write"])
        self.assertIn("NOT proven", action["stop"])
        for name in ("CoreSetAimConsumer.swift", "CoreSetRecoilConsumer.swift"):
            source = (ROOT / "lara/views/app" / name).read_text(encoding="utf-8")
            self.assertIn("audited-writer-or-receipt-unavailable", source)
            self.assertIn("supportedFields: Set<CoreSetField> { [] }", source)

    def test_slices_and_words_are_bounded_evidence(self):
        for window in NATIVE["proof_windows"]:
            self.assertEqual(len(window["instructions"]), 4)
            for index, instruction in enumerate(window["instructions"]):
                self.assertEqual(len(bytes.fromhex(instruction["bytes"])), 4)
                self.assertEqual(int(instruction["address"], 16), int(window["address"], 16) + index * 4)
        for point in POINTS["points"]:
            for read in point["native_read_sites"]:
                self.assertEqual(read["kind"], "read")
                self.assertEqual(read["basis"], "local explicit constant propagation")
        self.assertTrue(all("not asserted" in section["limit"]
                            for section in NATIVE["additional_state_slices"].values()))

    def test_negative_point_and_identity_controls(self):
        changes = [
            lambda p, n: p.update(reference_image_sha256="0" * 64),
            lambda p, n: p["points"][1].update(id="v17-000"),
            lambda p, n: p["points"][106].update(one_to_one_complete=True),
            lambda p, n: p["points"][108].update(alternative_preview=False),
            lambda p, n: p["points"][104]["storage"][0].update(offset="0x10c"),
            lambda p, n: p["points"][132]["storage"][0].update(owner="target-controller"),
            lambda p, n: n["configuration_tables"]["trigger_ui_to_storage"].update(values=[0, 1, 2, 3]),
            lambda p, n: n["action_timer_block"].update(decoded_invoke="0x1000c18a0"),
            lambda p, n: n.update(function_starts_present=True),
            lambda p, n: n["functions"]["frame_draw"]["unresolved_indirect_edges"].append({"instruction": "brk #0xc471"}),
        ]
        for change in changes:
            points, native = deepcopy(POINTS), deepcopy(NATIVE)
            change(points, native)
            with self.assertRaises(AssertionError):
                validate(points, native)

    def test_negative_chain_edge_not_replaced_by_keyword(self):
        points, native = deepcopy(POINTS), deepcopy(NATIVE)
        points["chain_profiles"]["read-hud"]["exact_edges"][0][2] = "0x1000db268"
        with self.assertRaises(AssertionError):
            validate(points, native)


def sample_replay(path: Path) -> None:
    specification = importlib.util.spec_from_file_location("v17_native_probe", ROOT / "tools/core_set_v17_function_chain_probe.py")
    probe = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(probe)
    core = probe.CoreImage(path)
    words = 0
    for window in NATIVE["proof_windows"]:
        for expected in window["instructions"]:
            address = int(expected["address"], 16)
            actual = core.instructions(address, 4)[0]
            assert core.file_offset(address) == int(expected["file_offset"], 16)
            assert bytes(actual.bytes).hex() == expected["bytes"]
            assert actual.mnemonic + " " + actual.op_str == expected["instruction"]
            words += 1
    for function in NATIVE["functions"].values():
        actual = core.describe_function(int(function["requested_anchor"], 16))
        for key in ("entry", "entry_file_offset", "candidate_end", "entry_basis", "end_basis"):
            assert actual[key] == function[key]
        for expected in function["inter_root_calls"]:
            assert expected in actual["calls"]
        assert actual["candidate_tail_calls"] == function["candidate_tail_calls"]
    assert core.action_timer_block() == NATIVE["action_timer_block"]
    assert core.configuration_tables() == NATIVE["configuration_tables"]
    assert core.read_transport_import() == NATIVE["read_transport_import"]
    print(f"PASS: identity-bound replay {words} instruction words, {len(NATIVE['functions'])} function candidates, timer block and int32 tables")
    print("LIMIT: no native execution, target read/write, original restore or device presentation result")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-ipa", type=Path)
    arguments = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativePointChainTests))
    if not result.wasSuccessful():
        raise SystemExit(1)
    if arguments.reference_ipa:
        sample_replay(arguments.reference_ipa)
    else:
        print("SKIP: external sample replay requires --reference-ipa; fixture contracts only")
