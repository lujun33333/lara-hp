#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace CoreSet {

enum class NameReadStatus { ok, skipped, readFailure };

// Build 15915 FName: UObject+0x18 index, a 14/14 indirect array, and a
// direct or dictionary-compressed ANSI FNameEntry. Only the ASCII base name is relevant to
// Core v1.7's case-sensitive substring keys; the instance number is ignored.
template <typename Read>
NameReadStatus readMaterialBaseName(Read read, uint64_t actor, uint64_t pool,
                                    std::string *name, uint64_t imageBase = 0) {
    if (!name || !actor || !pool) return NameReadStatus::skipped;
    name->clear();
    uint32_t index = 0, count = 0;
    if (!read(actor + 0x18, &index, sizeof(index)) ||
        !read(pool + 0x1400, &count, sizeof(count))) return NameReadStatus::readFailure;
    if (index == 0 || index >= count || count > 0xA00000) return NameReadStatus::skipped;
    uint32_t blockIndex = index >> 14, entryIndex = index & 0x3fff;
    if (blockIndex >= 0x280) return NameReadStatus::skipped;
    uint64_t block = 0, entry = 0;
    if (!read(pool + uint64_t(blockIndex) * 8, &block, sizeof(block)))
        return NameReadStatus::readFailure;
    if (!block) return NameReadStatus::skipped;
    if (block > UINT64_MAX - uint64_t(entryIndex) * 8) return NameReadStatus::skipped;
    if (!read(block + uint64_t(entryIndex) * 8, &entry, sizeof(entry)))
        return NameReadStatus::readFailure;
    if (!entry || entry > UINT64_MAX - 0xe - 128) return NameReadStatus::skipped;
    uint32_t flags = 0;
    uint16_t encodedLength = 0;
    if (!read(entry + 8, &flags, sizeof(flags)) ||
        !read(entry + 0xc, &encodedLength, sizeof(encodedLength))) return NameReadStatus::readFailure;
    if (flags & 1u) return NameReadStatus::skipped; // Wide names are not in the 177 ASCII keys.
    if (encodedLength) {
        if (!imageBase || imageBase > UINT64_MAX - 0x11fba5e8) return NameReadStatus::skipped;
        const uint32_t segments = encodedLength & 0xefffu;
        const bool extended = (encodedLength & 0x1000u) != 0;
        if (!segments || segments > 128) return NameReadStatus::skipped;
        // 0x108c15280/2b4: low 16-bit indices, optional high bytes, then
        // packed prefix nibbles. Dictionary slots are runtime pointers.
        const uint64_t low = entry + 0xe;
        const uint64_t high = low + uint64_t(segments) * 2;
        const uint64_t prefix = extended ? low + uint64_t(segments + (segments + 1) / 2) * 2 : high;
        uint64_t dictionary = 0;
        uint32_t dictionaryCount = 0;
        if (!read(imageBase + 0x11fba5e0, &dictionary, sizeof(dictionary)) ||
            !read(imageBase + 0x11fba5e8, &dictionaryCount, sizeof(dictionaryCount)))
            return NameReadStatus::readFailure;
        if (!dictionary || !dictionaryCount || dictionaryCount > 0x100000)
            return NameReadStatus::skipped;
        static constexpr char prefixes[15] = {'/', '.', '_', '$', 0, 'N', 'u', 'm',
                                               'b', 'e', 'r', 0, 'S', 't', 'r'};
        for (uint32_t i = 0; i < segments; ++i) {
            uint16_t lowIndex = 0;
            uint8_t highIndex = 0, packed = 0;
            if (!read(low + uint64_t(i) * 2, &lowIndex, sizeof(lowIndex)) ||
                (extended && !read(high + i, &highIndex, 1)) ||
                !read(prefix + i / 2, &packed, 1)) return NameReadStatus::readFailure;
            uint32_t symbol = uint32_t(lowIndex) | (uint32_t(highIndex) << 16);
            uint8_t nibble = uint8_t((packed >> ((i & 1u) * 4)) & 0xfu);
            if (symbol >= dictionaryCount) return NameReadStatus::skipped;
            if (nibble && prefixes[nibble - 1]) name->push_back(prefixes[nibble - 1]);
            uint64_t word = 0;
            if (dictionary > UINT64_MAX - uint64_t(symbol) * 8 ||
                !read(dictionary + uint64_t(symbol) * 8, &word, sizeof(word)))
                return NameReadStatus::readFailure;
            if (!word || word > UINT64_MAX - 4 - 128) return NameReadStatus::skipped;
            uint32_t live = 0;
            if (!read(word, &live, sizeof(live))) return NameReadStatus::readFailure;
            if (!live) continue;
            bool terminated = false;
            for (size_t j = 0; name->size() < 128 && j < 128; ++j) {
                uint8_t byte = 0;
                if (!read(word + 4 + j, &byte, 1)) return NameReadStatus::readFailure;
                if (!byte) { terminated = true; break; }
                if (byte < 0x20 || byte > 0x7e) return NameReadStatus::skipped;
                name->push_back(char(byte));
            }
            if (!terminated) return NameReadStatus::skipped;
        }
        return name->empty() ? NameReadStatus::skipped : NameReadStatus::ok;
    }
    for (size_t i = 0; i < 128; ++i) {
        uint8_t byte = 0;
        if (!read(entry + 0xe + i, &byte, 1)) return NameReadStatus::readFailure;
        if (!byte) return name->empty() ? NameReadStatus::skipped : NameReadStatus::ok;
        if (byte < 0x20 || byte > 0x7e) return NameReadStatus::skipped;
        name->push_back(char(byte));
    }
    name->clear();
    return NameReadStatus::skipped;
}

inline uint32_t materialNameHash(const std::string &name) {
    uint32_t hash = 0x811c9dc5u;
    for (unsigned char byte : name) hash = (hash ^ byte) * 0x01000193u;
    return hash;
}

inline size_t firstMaterialMatch(const std::string &name,
                                 const std::string *patterns, size_t count) {
    if (name.empty() || !patterns) return count;
    for (size_t i = 0; i < count; ++i)
        if (!patterns[i].empty() && name.find(patterns[i]) != std::string::npos) return i;
    return count;
}

// Core d9d00/d9d40 checks EscapeBox then Lv3_5 before Lv1..Lv7. This
// returns only a name-encoded class tier; it never infers opened state.
inline std::string escapeBoxLevelLabel(const std::string &name) {
    if (name.find("EscapeBox") == std::string::npos) return {};
    const auto boundary = [&name](size_t end) {
        return end >= name.size() || name[end] < '0' || name[end] > '9';
    };
    size_t position = name.find("Lv3_5");
    if (position != std::string::npos)
        return boundary(position + 5) ? "Lv3.5" : std::string{};
    for (char number = '1'; number <= '7'; ++number) {
        std::string key = "Lv";
        key.push_back(number);
        position = name.find(key);
        if (position != std::string::npos && boundary(position + key.size())) return key;
    }
    return {};
}

} // namespace CoreSet
