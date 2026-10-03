#pragma once

#include <cstdint>

namespace CoreSet {

// Core v1.7 e03c0 -> dfa10 canonical RepWeaponID text subset. Unknown and
// noncanonical IDs intentionally produce no label; no numeric fallback.
inline const char *weaponNameForCanonicalID(uint32_t id) {
    switch (id) {
    case 101001: return "AKM";
    case 101002: return "M16A4";
    case 101003: return "SCAR-L";
    case 101004: return "M416";
    case 101005: return "GROZA";
    case 101006: return "AUG";
    case 101007: return "QBZ";
    case 101008: return "M762";
    case 101009: return "Mk47";
    case 101010: return "G36C";
    case 101011: return "AC-VAL";
    case 101012: return "蜜獾";
    case 101013: return "FAMAS";
    case 101014: return "ACE32";
    case 101016: return "ARX200";
    case 102001: return "UZI";
    case 102002: return "UMP45";
    case 102003: return "Vector";
    case 102004: return "汤姆逊";
    case 102005: return "野牛";
    case 102007: return "MP5K";
    case 102008: return "AKS-74U";
    case 102009: return "JS9";
    case 102105: return "P90";
    case 103001: return "Kar98K";
    case 103002: return "M24";
    case 103003: return "AWM";
    case 103004: return "SKS";
    case 103005: return "VSS";
    case 103006: return "Mini14";
    case 103007: return "Mk14";
    case 103008: return "Win94";
    case 103009: return "SLR";
    case 103010: return "QBU";
    case 103011: return "莫辛纳甘";
    case 103012: return "AMR";
    case 103013: return "M417";
    case 103014: return "MK20-H";
    case 103015: return "M200";
    case 103016: return "SVD";
    case 103100: return "MK12";
    case 103101: return "电磁步枪";
    case 103901: return "Kar98K";
    case 103902: return "M24";
    case 103903: return "AWM";
    case 103904: return "AMR";
    case 103905: return "M200";
    case 103906: return "Mk14";
    case 104001: return "S686";
    case 104002: return "S1897";
    case 104003: return "S12K";
    case 104004: return "DBS";
    case 104005: return "AA12-G";
    case 104100: return "SPAS-12";
    case 105001: return "M249";
    case 105002: return "DP-28";
    case 105010: return "MG3";
    case 105012: return "PKM";
    case 105013: return "MG-36";
    case 106001: return "P92";
    case 106002: return "P1911";
    case 106003: return "R1895";
    case 106004: return "P18C";
    case 106005: return "R45";
    case 106006: return "短管霰弹枪";
    case 106007: return "信号枪";
    case 106008: return "蝎式手枪";
    case 106010: return "沙漠之鹰";
    case 106011: return "TMP-9";
    case 106013: return "FN57";
    case 107001: return "十字弩";
    case 107002: return "RPG-7";
    case 107006: return "战术弩";
    case 107007: return "爆炸猎弓";
    case 107008: return "燃点复合弓";
    case 107010: return "突击盾牌";
    case 107100: return "M79榴弹";
    case 107909: return "轻型迫击炮";
    case 107910: return "和平使者";
    case 108001: return "大砍刀";
    case 108002: return "撬棍";
    case 108003: return "镰刀";
    case 108004: return "平底锅";
    case 602001: return "震爆弹";
    case 602002: return "烟雾弹";
    case 602003: return "燃烧瓶";
    case 602004: return "手榴弹";
    case 602075: return "铝热弹";
    case 602104: return "大砍刀";
    default: return nullptr;
    }
}

} // namespace CoreSet
