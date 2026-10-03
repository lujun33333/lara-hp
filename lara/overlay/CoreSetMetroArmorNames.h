#pragma once

#include <cstdint>

namespace CoreSet {

// Core v1.7 maps at 0x100c51fe0 (head) and 0x100c51ff8 (armor).
// These are TypeSpecificID values, not name-derived item categories.
inline const char *metroHeadLabel(uint32_t id) {
    switch (id) {
    case 0: return "无";
    case 502104: case 502107: case 502110:
    case 9804021: case 9804004: case 9804005: case 9804006: return "4";
    case 502105: case 502111: case 502108:
    case 9804022: case 9804007: case 9804008: case 9804009: return "5";
    case 502106: case 502109: case 502112:
    case 9804023: case 9804010: case 9804011: case 9804012: return "6";
    case 9804024: case 9804013: case 9804014: case 9804015: return "7";
    case 9804017: case 9804018: case 9804019: case 9804025: return "金";
    case 9804016: return "夜";
    case 9804026: return "墨";
    case 9804020: return "机";
    default: return nullptr;
    }
}

inline const char *metroArmorLabel(uint32_t id) {
    switch (id) {
    case 0: return "无";
    case 503104: case 503107: case 503110:
    case 9805004: case 9805005: case 9805006: case 9805021: case 9805022:
    case 9805023: case 9805036: case 9805041: return "4";
    case 503105: case 503108: case 503111:
    case 9805007: case 9805008: case 9805009: case 9805024: case 9805025:
    case 9805026: case 9805037: case 9805042: return "5";
    case 503106: case 503109: case 503112:
    case 9805010: case 9805011: case 9805012: case 9805027: case 9805028:
    case 9805029: case 9805038: case 9805043: return "6";
    case 9805013: case 9805014: case 9805015: case 9805030: case 9805031:
    case 9805032: case 9805098: case 9805099: case 9805039: case 9805044: return "7";
    case 9805016: case 9805017: case 9805018: case 9805033: case 9805034:
    case 9805035: case 9805040: case 9805045: return "金";
    case 9805100: case 9805101: case 9805102: case 9805103: return "威";
    case 9805094: case 9805095: case 9805096: case 9805097: return "特";
    case 9805020: return "机";
    default: return nullptr;
    }
}

} // namespace CoreSet
