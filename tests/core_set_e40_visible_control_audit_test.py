"""Offline visible controls must have an explicit local or unavailable scope."""

import copy
import json
from pathlib import Path
from core_set_basic_aim_boundary import BASIC_FIELDS, PROFILE_GUARD, assert_basic_aim_boundary


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "artifacts/core-set-v1.7/ui-point-inventory.json"
PATHS = (ROOT / "lara/views/app/CoreSetAimConsumer.swift",
         ROOT / "lara/views/app/CoreSetRecoilConsumer.swift",
         ROOT / "lara/views/app/CoreSetFrameRateConsumer.swift",
         ROOT / "lara/views/app/CoreSetRuntimeCoordinator.swift")


def gate(inventory: dict, source: list[str]) -> None:
    points = inventory["points"]
    assert len(points) == 137
    required = [row for row in points if row.get("required_field")]
    assert len(required) == 68
    assert all(row.get("source_consumer") and row.get("field_availability") for row in required)
    assert [row["required_field"] for row in required if not row.get("supportedField")] == ["framesPerSecond"]
    enabled_required = [row for row in required if row.get("enabled")]
    assert len(enabled_required) == 3
    assert {row["required_field"] for row in enabled_required} == {"materialColor", "materialGroupSelection"}
    assert all("本地" in row.get("status", "") and "不影响游戏" in row.get("status", "")
               for row in enabled_required)
    assert all(row.get("status") for row in points if not row.get("enabled") and not row.get("required_field"))
    for field in ("actor(player,weapon)", "actor(bot,weapon)"):
        row = next(point for point in required if point["required_field"] == field)
        assert row["mode_availability"]["image"].startswith("conditional:")
    contracts = inventory["e_field_contract"]
    for key in ("playerRendering", "materialFiltering", "drawingAppearance", "radarRendering"):
        assert contracts[key]["supported_count"] == 0 and contracts[key]["page_ready"] is False
    assert contracts["frameScheduling"]["supported_count"] == 0
    assert contracts["frameScheduling"]["current_backend_ready"] is False
    assert contracts["localAimDisplay"]["supported_count"] == 0
    assert contracts["localAimDisplay"]["aimControl_ready"] is False
    aim, recoil, fps, coordinator = source
    assert_basic_aim_boundary(aim)
    assert "var supportedFields: Set<CoreSetField> { [] }" in recoil
    assert "未执行目标写入" in recoil
    assert "coordinator?.frameRateReady == true ? .ready" in fps
    assert "coordinator?.applyFrameRate(value) == true" in fps
    assert "coordinator?.restoreFrameRate() == true" in fps
    assert "host.renderFPSControlReady && host.observedRenderFPS() >= 30" in coordinator
    for key in ("frame.generation == item.submission.hostGeneration",
                "frame.configRevision == item.submission.configRevision",
                "frame.snapshotID == item.submission.snapshotID.uuidString",
                "frame.requestToken == expected", "acceptedByLocalRenderer: accepted"):
        assert key in coordinator
    assert "pending.removeValue(forKey: frame.sequence)" in coordinator


def main() -> None:
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    source = [p.read_text(encoding="utf-8") for p in PATHS]
    gate(inventory, source)
    mutations = (
        ("point", "framesPerSecond", "supportedField", True),
        ("point", "actor(player,weapon)", "mode_availability", {"image": "ready"}),
        ("point", "materialColor", "status", "游戏已应用"),
        ("point", "materialGroupSelection", "source_consumer", ""),
        ("point", None, "status", ""),
        ("contract", "playerRendering", "page_ready", True),
        ("contract", "localAimDisplay", "aimControl_ready", True),
        ("source", 0, BASIC_FIELDS, "[.aimEnabled]"),
        ("source", 0, PROFILE_GUARD, "guard true else"),
        ("source", 1, "var supportedFields: Set<CoreSetField> { [] }", "var supportedFields: Set<CoreSetField> { [.recoilEnabled] }"),
        ("source", 2, "coordinator?.applyFrameRate(value) == true", "true"),
        ("source", 3, "frame.requestToken == expected", "true"),
        ("source", 3, "acceptedByLocalRenderer: accepted", "acceptedByLocalRenderer: true"),
    )
    for mutation in mutations:
        changed = copy.deepcopy(inventory)
        altered = source.copy()
        kind, key, field, value = mutation
        if kind == "point":
            if key is None:
                row = next(row for row in changed["points"] if not row.get("enabled") and
                           not row.get("required_field") and row.get("status"))
            else:
                row = next(row for row in changed["points"] if row.get("required_field") == key)
            row[field] = value
        elif kind == "contract":
            changed["e_field_contract"][key][field] = value
        else:
            assert field in altered[key]
            altered[key] = altered[key].replace(field, value, 1)
        try:
            gate(changed, altered)
        except AssertionError:
            continue
        raise AssertionError(f"unsafe visible-control mutation passed: {mutation}")
    print(f"PASS: E40 137 historical points, 68 field boundaries, {len(mutations)} false-ready negatives")


if __name__ == "__main__":
    main()
