#pragma once

#include <stddef.h>
#include <stdint.h>

// Core-self publication records. None of these offsets belong to a target
// game object and neither record grants a target-write route.
#pragma pack(push, 1)
typedef struct CoreSetActionCandidateRawRecord {
    uint8_t valid;
    uint8_t reserved01[7];
    uint64_t candidateKey;
    float target[3];
    float camera[3];
    float normalizedScreenError;
    uint8_t reserved2C[4];
    uint64_t publicationSerial;
    uint8_t sameAsPrevious;
    uint8_t hadPrevious;
} CoreSetActionCandidateRawRecord;
#pragma pack(pop)

typedef struct CoreSetActionInputAuthorityRawRecord {
    int32_t processID;
    uint32_t reserved04;
    uint64_t imageBase;
    uint64_t sessionGeneration;
    uint64_t controllerAddress;
    uint64_t localActorAddress;
    uint8_t snapshotID[16];
    double captureStartedMonotonicSeconds;
    double captureCompletedMonotonicSeconds;
    uint8_t localADS;
    uint8_t localFiring;
    uint8_t localFiringRaw;
    uint8_t recoilInputsPresent;
    uint8_t routeAuthorityResolved;
    int8_t resolvedActionSlot;
    uint8_t reserved56[2];
    float controlPitchDegrees;
    float controlYawDegrees;
    float rotationInputPitch;
    float rotationInputYaw;
    uint32_t recoilBinding;
    uint32_t reserved6C;
    uint64_t recoilKey;
    uint64_t recoilOwnerToken;
    uint8_t recoilActive;
    uint8_t reserved81[3];
    float recoilValues[6];
    float recoilScales[4];
} CoreSetActionInputAuthorityRawRecord;

#if defined(__cplusplus)
#include <algorithm>
#include <array>
#include <cmath>
#include <mutex>
#include <type_traits>
static_assert(std::is_standard_layout_v<CoreSetActionCandidateRawRecord>);
static_assert(std::is_trivially_copyable_v<CoreSetActionCandidateRawRecord>);
static_assert(sizeof(CoreSetActionCandidateRawRecord) == 0x3a);
static_assert(offsetof(CoreSetActionCandidateRawRecord, valid) == 0x00);
static_assert(offsetof(CoreSetActionCandidateRawRecord, candidateKey) == 0x08);
static_assert(offsetof(CoreSetActionCandidateRawRecord, target) == 0x10);
static_assert(offsetof(CoreSetActionCandidateRawRecord, camera) == 0x1c);
static_assert(offsetof(CoreSetActionCandidateRawRecord, normalizedScreenError) == 0x28);
static_assert(offsetof(CoreSetActionCandidateRawRecord, publicationSerial) == 0x30);
static_assert(offsetof(CoreSetActionCandidateRawRecord, sameAsPrevious) == 0x38);
static_assert(offsetof(CoreSetActionCandidateRawRecord, hadPrevious) == 0x39);
static_assert(std::is_standard_layout_v<CoreSetActionInputAuthorityRawRecord>);
static_assert(std::is_trivially_copyable_v<CoreSetActionInputAuthorityRawRecord>);

namespace CoreSet {

struct ActionPublicationIdentity {
    uint64_t generation = 0;
    int32_t pid = -1;
    uint64_t imageBase = 0;
    uint64_t controller = 0;
    friend bool operator==(const ActionPublicationIdentity &a,
                           const ActionPublicationIdentity &b) {
        return a.generation == b.generation && a.pid == b.pid &&
            a.imageBase == b.imageBase && a.controller == b.controller;
    }
};

struct ActionCandidatePublicationInput {
    ActionPublicationIdentity identity{};
    uint64_t candidateKey = 0;
    std::array<float, 3> target{};
    std::array<float, 3> camera{};
    double bestPixels = 0;
    double radius = 0;
    double capturedAt = 0;
};

struct ActionCandidatePublicationCopy {
    CoreSetActionCandidateRawRecord record{};
    ActionPublicationIdentity identity{};
    double capturedAt = 0;
};

// The only mutex owner for the compact publication. The full actor snapshot is
// intentionally absent from this type.
class ActionCandidatePublicationState {
public:
    bool publish(const ActionCandidatePublicationInput &input,
                 ActionCandidatePublicationCopy *out) {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!out || !valid(input) || serial_ == UINT64_MAX) return false;
        const bool identitySame = hasRecord_ && input.identity == identity_;
        const bool had = identitySame && record_.valid && record_.candidateKey;
        const bool same = had && record_.candidateKey == input.candidateKey;
        CoreSetActionCandidateRawRecord next{};
        next.valid = 1; next.candidateKey = input.candidateKey;
        std::copy(input.target.begin(), input.target.end(), next.target);
        std::copy(input.camera.begin(), input.camera.end(), next.camera);
        next.normalizedScreenError = same ? 0.0f :
            static_cast<float>(std::clamp(input.bestPixels / input.radius, 0.0, 1.0));
        next.publicationSerial = ++serial_;
        next.sameAsPrevious = same ? 1 : 0; next.hadPrevious = had ? 1 : 0;
        record_ = next; identity_ = input.identity; capturedAt_ = input.capturedAt;
        hasRecord_ = true; *out = {record_, identity_, capturedAt_}; return true;
    }
    bool publishMissing(ActionPublicationIdentity identity, double capturedAt,
                        ActionCandidatePublicationCopy *out) {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!out || !validIdentity(identity) || !std::isfinite(capturedAt) ||
            capturedAt < 0 || !hasRecord_ || !(identity == identity_) ||
            capturedAt < capturedAt_ || capturedAt - capturedAt_ > 0.075000001 ||
            serial_ == UINT64_MAX) {
            clearLocked(); return false;
        }
        record_.publicationSerial = ++serial_;
        record_.sameAsPrevious = 1; record_.hadPrevious = 1;
        capturedAt_ = capturedAt; *out = {record_, identity_, capturedAt_}; return true;
    }
    bool copy(ActionCandidatePublicationCopy *out) const {
        std::lock_guard<std::mutex> guard(mutex_);
        if (!out || !hasRecord_ || !record_.valid || !record_.publicationSerial) return false;
        *out = {record_, identity_, capturedAt_}; return true;
    }
    void clear() { std::lock_guard<std::mutex> guard(mutex_); clearLocked(); }
    uint64_t serial() const { std::lock_guard<std::mutex> guard(mutex_); return serial_; }
private:
    static bool validIdentity(const ActionPublicationIdentity &value) {
        return value.generation && value.pid > 0 && value.imageBase && value.controller;
    }
    static bool validPoint(const std::array<float, 3> &point) {
        return std::all_of(point.begin(), point.end(), [](float value) { return std::isfinite(value); });
    }
    static bool valid(const ActionCandidatePublicationInput &input) {
        return validIdentity(input.identity) && input.candidateKey && validPoint(input.target) &&
            validPoint(input.camera) && std::isfinite(input.bestPixels) && input.bestPixels >= 0 &&
            std::isfinite(input.radius) && input.radius > 1 &&
            std::isfinite(input.capturedAt) && input.capturedAt >= 0;
    }
    void clearLocked() {
        record_ = {}; identity_ = {}; capturedAt_ = 0; hasRecord_ = false;
    }
    mutable std::mutex mutex_;
    CoreSetActionCandidateRawRecord record_{};
    ActionPublicationIdentity identity_{};
    double capturedAt_ = 0;
    uint64_t serial_ = 0;
    bool hasRecord_ = false;
};

} // namespace CoreSet
#endif
