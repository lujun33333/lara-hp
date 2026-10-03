"""Fixed AX snapshot -> direct ImDraw primitive-plan golden test."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "lara/kexploit/WZHUDBridge.mm").read_text(encoding="utf-8")
EXPECTED_SHA256 = "040e7db97a92280938e7d41a756bc8ece5c0c352e113a96224e63b58f9dfe508"

SHOW_AVATAR = 1 << 0
SHOW_HEALTH = 1 << 1
SHOW_RECALL = 1 << 2
SHOW_BOX = 1 << 4
SHOW_ENEMY_VISION = 1 << 6
SHOW_MINIMAP = 1 << 7
SHOW_MONSTER = 1 << 8
SHOW_MONSTER_TIMER = 1 << 10
SHOW_SOLDIER = 1 << 11
SHOW_SKILL = 1 << 14


def f(value: float) -> float:
    return round(float(value), 6)


def produce(config: dict, items: list[dict], frame_time: float, bounds: tuple[float, float]):
    out: list[list[object]] = []
    flags = config["flags"]
    if flags & SHOW_SKILL and config["skill_size"] > 0:
        skill_index = 0
        for item in items:
            if skill_index >= 5:
                break
            if item["category"] != "hero" or not item.get("enemy") or item["config_id"] <= 0:
                continue
            size = config["skill_size"]
            row_x = config["skill_x"] + (size + 3) * skill_index
            small_size = (size - 5) / 2.5
            small_x = row_x + size * 0.5 - small_size * 0.5
            small_y = config["skill_y"] + 1.5
            hero_y = small_y + small_size + 2
            summoner_y = hero_y + size + 2
            text_size = (size - 10) * 0.5 + 6
            if item["aux"] <= 0 and small_size > 0:
                out.append(["circle_fill", f(small_x + small_size / 2), f(small_y + small_size / 2), f(small_size / 2), "00ff00ff"])
            elif item["aux"] > 0:
                out.append(["text_outline", str(round(item["aux"])), f(small_x), f(small_y), f(small_size), f(small_size), f(text_size), "ffde40ff"])
            out.append(["image_round", f(row_x), f(hero_y), f(size), f(size), f(size / 2), f"hero:{item['config_id']}"])
            out.append(["circle", f(row_x + size / 2), f(hero_y + size / 2), f(size / 2), "ff0000ff", 1.0])
            skill_id = item["skill_id"] or 80108
            out.append(["image_round", f(row_x), f(summoner_y), f(size), f(size), f(size / 2), f"skill:{skill_id}"])
            out.append(["circle", f(row_x + size / 2), f(summoner_y + size / 2), f(size / 2), "ff0000ff", 1.0])
            if item["skill_cd"] > 0:
                out.append(["circle_fill", f(row_x + size / 2), f(summoner_y + size / 2), f(max(0, size / 2 - 0.5)), "00000076"])
                out.append(["text_outline", str(round(item["skill_cd"])), f(row_x), f(summoner_y), f(size), f(size), f(text_size), "ffde40ff"])
            skill_index += 1

    width, height = bounds
    for item in items:
        if item["primitive"] == "exposure":
            if item["on_screen"] and item["radius"] > 0:
                out.append(["circle_fill", f(item["screen_x"]), f(item["screen_y"]), f(item["radius"]), item["rgba"]])
            continue
        if item["category"] == "hero" and item["on_screen"]:
            if flags & SHOW_BOX:
                out.append(["rect", f(item["screen_x"] - 20), f(item["screen_y"] - 50), f(item["screen_x"] + 20), f(item["screen_y"] + 10), "00ff00ff", 0.0, 0, 1.0])
            if flags & SHOW_AVATAR:
                portrait_size = config["map_size"] / 15.4 * 2
                center_y = item["screen_y"] - 8
                out.append(["image_round", f(item["screen_x"] - portrait_size / 2), f(center_y - portrait_size / 2), f(portrait_size), f(portrait_size), f(portrait_size / 2), f"hero:{item['config_id']}"])
                out.append(["circle", f(item["screen_x"]), f(center_y), f(portrait_size / 2), "ff0000ff", 1.0])

        show_hero = item["category"] == "hero" and flags & SHOW_MINIMAP
        show_monster = item["category"] == "monster" and item["primitive"] == "monster_point" and item["slot"] < 16 and flags & SHOW_MONSTER
        show_soldier = item["category"] == "soldier" and item["primitive"] == "soldier_point" and flags & SHOW_SOLDIER
        show_timer = item["category"] == "monster" and item["primitive"] == "monster_timer" and flags & SHOW_MONSTER_TIMER
        if (show_hero or show_monster or show_soldier) and item["map_valid"]:
            if show_hero:
                radius = config["map_size"] / 17
                out.append(["image_round", f(item["map_x"] - radius), f(item["map_y"] - radius), f(radius * 2), f(radius * 2), f(radius), f"hero:{item['config_id']}"])
            elif show_monster:
                radius = config["map_size"] / 51 + (1 if item["slot"] in (0, 4, 8, 12) else 0)
                color = "0000ffff" if item["slot"] in (0, 8) else ("ff0000ff" if item["slot"] in (4, 12) else "ffffffff")
                out.append(["circle_fill", f(item["map_x"]), f(item["map_y"]), f(radius), color])
            else:
                radius = config["map_size"] / 65.5
                out.append(["circle_fill", f(item["map_x"]), f(item["map_y"]), f(radius), "ff0000ff"])
            if show_hero:
                if flags & SHOW_ENEMY_VISION and item["exposure_valid"] and item["dimmed"]:
                    out.append(["circle_fill", f(item["map_x"]), f(item["map_y"]), f(radius), "00000032"])
                if item["recall"] and flags & SHOW_RECALL:
                    rotation = frame_time * 2.5
                    for index in range(4):
                        start = rotation + index * math.pi / 2
                        out.append(["arc", f(item["map_x"]), f(item["map_y"]), f(radius + 1), f(start), f(start + 1.0995573997497559), "64dcffff", 2.0])
                        out.append(["arc", f(item["map_x"]), f(item["map_y"]), f(radius + 1), f(start), f(start + 0.5497786998748779), "2878c8b4", 1.5])
                    out.append(["circle", f(item["map_x"]), f(item["map_y"]), f(radius), "3c8cdc50", 1.0])
                if flags & SHOW_HEALTH:
                    ratio = min(1, max(0, item["health"]))
                    out.append(["arc", f(item["map_x"]), f(item["map_y"]), f(radius + 1), f(-math.pi / 2), f(-math.pi / 2 + math.pi * 2 * ratio), "b9b900ff", 1.8])
        if show_timer and item["slot"] < 16 and item["map_valid"] and item["cooldown"] != 0:
            size = config["map_size"] / 26 * 1.9
            offset = config["map_size"] / 26 * 0.5
            color = "ffff00ff" if item["slot"] % 4 == 0 else "ffffffff"
            out.append(["text", str(int(item["cooldown"])), f(item["map_x"] - offset), f(item["map_y"] - offset), f(size), color])
    return out


flags = SHOW_AVATAR | SHOW_HEALTH | SHOW_RECALL | SHOW_BOX | SHOW_ENEMY_VISION | SHOW_MINIMAP | SHOW_MONSTER | SHOW_MONSTER_TIMER | SHOW_SOLDIER | SHOW_SKILL
config = {"flags": flags, "map_size": 170.0, "skill_size": 30.0, "skill_x": 10.0, "skill_y": 20.0}
items = [
    {"category": "hero", "primitive": "entity", "enemy": True, "config_id": 105, "skill_id": 0, "aux": 12.0, "skill_cd": 8.0, "screen_x": 100.0, "screen_y": 200.0, "on_screen": True, "map_x": 300.0, "map_y": 400.0, "map_valid": True, "slot": -1, "recall": True, "health": 0.5, "exposure_valid": True, "dimmed": True, "radius": 0, "rgba": "00000000", "cooldown": 0},
    {"category": "monster", "primitive": "monster_point", "enemy": True, "config_id": 0, "skill_id": 0, "aux": 0, "skill_cd": 0, "screen_x": 0, "screen_y": 0, "on_screen": False, "map_x": 50.0, "map_y": 60.0, "map_valid": True, "slot": 0, "recall": False, "health": 0, "exposure_valid": False, "dimmed": False, "radius": 0, "rgba": "00000000", "cooldown": 0},
    {"category": "monster", "primitive": "monster_timer", "enemy": True, "config_id": 0, "skill_id": 0, "aux": 0, "skill_cd": 0, "screen_x": 0, "screen_y": 0, "on_screen": False, "map_x": 70.0, "map_y": 80.0, "map_valid": True, "slot": 4, "recall": False, "health": 0, "exposure_valid": False, "dimmed": False, "radius": 0, "rgba": "00000000", "cooldown": 37},
    {"category": "soldier", "primitive": "soldier_point", "enemy": True, "config_id": 0, "skill_id": 0, "aux": 0, "skill_cd": 0, "screen_x": 0, "screen_y": 0, "on_screen": False, "map_x": 90.0, "map_y": 100.0, "map_valid": True, "slot": -1, "recall": False, "health": 0, "exposure_valid": False, "dimmed": False, "radius": 0, "rgba": "00000000", "cooldown": 0},
    {"category": "hero", "primitive": "exposure", "enemy": True, "config_id": 0, "skill_id": 0, "aux": 0, "skill_cd": 0, "screen_x": 110.0, "screen_y": 120.0, "on_screen": True, "map_x": 0, "map_y": 0, "map_valid": False, "slot": -1, "recall": False, "health": 0, "exposure_valid": False, "dimmed": False, "radius": 3.0, "rgba": "11223344", "cooldown": 0},
]
commands = produce(config, items, 0.5, (844.0, 390.0))
payload = json.dumps(commands, ensure_ascii=False, separators=(",", ":")).encode()
actual_sha256 = hashlib.sha256(payload).hexdigest()
assert len(commands) == 26, len(commands)
assert actual_sha256 == EXPECTED_SHA256, actual_sha256

for required in (
    "ax_build_render_commands(latest, latestCount, current_wz_config()",
    "submitCommands:&frame.commands",
    "present_layer_frame_main(frame)",
    "buildDirectDrawList:(ImDrawList *)drawList",
    "drawList->AddRect",
    "drawList->AddLine",
    "drawList->AddImageRounded",
    "drawList->AddCircleFilled",
    "drawList->AddCircle",
    "drawList->AddText",
    "drawList->PathArcTo",
):
    assert required in SOURCE, required
for forbidden in ("CGPathApply", "for (CALayer *layer in _commands)", "appendShapeLayer",
                  "CGPathCreateCopyByTransformingPath"):
    assert forbidden not in SOURCE, forbidden

print(f"PASS: fixed snapshot -> {len(commands)} direct ImDraw semantic commands ({actual_sha256})")
