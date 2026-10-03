#include <cassert>
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>

static std::map<uint64_t, uint8_t> gMemory;
static size_t gReadCount = 0;
static size_t gTerminalChangeResetCount = 0;

extern "C" long wz_read(uint64_t address, void *output, size_t size);
extern "C" long wz_read_fresh_root(uint64_t address, void *output,
                                     size_t size, uint64_t *rebuildCount);
extern "C" const char *wz_transport_name(void);
extern "C" void YuanbaoCollectorResetForTerminalChange(void);

#include "../lara/kexploit/wz/KoiProjection.mm"

template <typename T>
static void StoreValue(uint64_t address, const T &value) {
    const auto *bytes = reinterpret_cast<const uint8_t *>(&value);
    for (size_t index = 0; index < sizeof(value); ++index) {
        gMemory[address + index] = bytes[index];
    }
}

static void StoreMatrix(uint64_t address, float m0, float m10) {
    float matrix[16]{};
    matrix[0] = m0;
    matrix[10] = m10;
    const auto *bytes = reinterpret_cast<const uint8_t *>(matrix);
    for (size_t index = 0; index < sizeof(matrix); ++index) {
        gMemory[address + index] = bytes[index];
    }
}

extern "C" long wz_read(uint64_t address, void *output, size_t size) {
    ++gReadCount;
    auto *bytes = static_cast<uint8_t *>(output);
    for (size_t index = 0; index < size; ++index) {
        const auto found = gMemory.find(address + index);
        if (found == gMemory.end()) return -1;
        bytes[index] = found->second;
    }
    return static_cast<long>(size);
}
extern "C" long wz_read_fresh_root(uint64_t, void *, size_t, uint64_t *) {
    return -1;
}
extern "C" const char *wz_transport_name(void) { return "projection-test"; }
extern "C" void YuanbaoCollectorResetForTerminalChange(void) {
    ++gTerminalChangeResetCount;
}

int main() {
    float matrix[16]{};
    assert(!KoiProjectionMatrixLooksValid(matrix));
    matrix[0] = 1.0f;
    assert(KoiProjectionMatrixLooksValid(matrix));
    matrix[0] = 0.0f;
    matrix[10] = 1.0f;
    assert(KoiProjectionMatrixLooksValid(matrix));
    matrix[0] = std::numeric_limits<float>::quiet_NaN();
    matrix[10] = 0.0f;
    assert(KoiProjectionMatrixLooksValid(matrix));

    KoiProjectionState projection{};
    KoiProjectionReset(&projection);
    assert(projection.matrix[0] == 0.0f);
    assert(projection.campOrientation == -1.0f);

    projection.screenWidth = 200.0f;
    projection.screenHeight = 100.0f;
    projection.matrix[0] = 1.0f;
    projection.matrix[9] = 1.0f;
    projection.matrix[14] = -2.0f;
    float x = -1.0f, y = -1.0f, w = 0.0f;
    assert(KoiProjectionWorldToScreen(
        &projection, 1.0f, 99.0f, 1.0f, &x, &y, &w));
    // 0x10080425c takes fabs(-2), then 0x1008042d4..0x1008042e8
    // applies (1 + clipX/W, 1 - clipY/W) * (width,height) * 0.5.
    assert(x == 150.0f && y == 25.0f && w == -2.0f);

    projection.matrix[14] = -0.005f;
    x = 7.0f;
    y = 8.0f;
    assert(!KoiProjectionWorldToScreen(
        &projection, 0.0f, 0.0f, 0.0f, &x, &y, nullptr));
    assert(x == 7.0f && y == 8.0f);

    float minimapX = 0.0f;
    float minimapY = 0.0f;
    assert(KoiProjectionMinimapPoint(
        50.0f, 50.0f, 10.0f, 100.0f, 1.0f,
        &minimapX, &minimapY));
    assert(std::fabs(minimapX - 110.0f) < 0.0001f);
    assert(std::fabs(minimapY) < 0.0001f);
    assert(KoiProjectionMinimapPoint(
        50.0f, 50.0f, 10.0f, 100.0f, -1.0f,
        &minimapX, &minimapY));
    assert(std::fabs(minimapX - 10.0f) < 0.0001f);
    assert(std::fabs(minimapY - 100.0f) < 0.0001f);

    // AX 0x100805720..0x1008057d0 caches the resolved matrix terminal for
    // 350 ms, while 0x10080585c..0x100805868 still reads its payload on each
    // frame. Force the deadline rather than relying on wall-clock timing.
    constexpr uintptr_t unity = UINT64_C(0x200000000);
    constexpr uintptr_t rootSlot = unity + UINT64_C(0x12CA9580);
    constexpr uintptr_t rootA = UINT64_C(0x300000000);
    constexpr uintptr_t ownerA = UINT64_C(0x300001000);
    constexpr uintptr_t holderA = UINT64_C(0x300002000);
    constexpr uintptr_t cameraA = UINT64_C(0x300003000);
    constexpr uintptr_t matrixA = cameraA + 0x128;
    StoreValue(rootSlot, rootA);
    StoreValue(rootA + 0xB8, ownerA);
    StoreValue(ownerA, holderA);
    StoreValue(holderA + 0x8, cameraA);
    StoreMatrix(matrixA, 1.0f, 1.0f);

    gMatrixAddressCache = {};
    gReadCount = 0;
    assert(KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixAddress == matrixA);
    assert(gReadCount == 5);
    assert(gTerminalChangeResetCount == 0);

    gMatrixAddressCache.nextProbe = UINT64_MAX;
    const size_t beforeCachedFrame = gReadCount;
    assert(KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixAddress == matrixA);
    assert(gReadCount == beforeCachedFrame + 1);
    assert(gTerminalChangeResetCount == 0);

    constexpr uintptr_t rootB = UINT64_C(0x400000000);
    constexpr uintptr_t ownerB = UINT64_C(0x400001000);
    constexpr uintptr_t holderB = UINT64_C(0x400002000);
    constexpr uintptr_t cameraB = UINT64_C(0x400003000);
    constexpr uintptr_t matrixB = cameraB + 0x128;
    StoreValue(rootSlot, rootB);
    StoreValue(rootB + 0xB8, ownerB);
    StoreValue(ownerB, holderB);
    StoreValue(holderB + 0x8, cameraB);
    StoreMatrix(matrixB, -1.0f, 1.0f);
    assert(KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixAddress == matrixA);
    gMatrixAddressCache.nextProbe = 0;
    const size_t beforeRefresh = gReadCount;
    assert(KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixAddress == matrixB);
    assert(projection.campOrientation == -1.0f);
    assert(gReadCount == beforeRefresh + 5);
    assert(gTerminalChangeResetCount == 1);

    // AX resets before checking the replacement terminal's pointer range.
    constexpr uintptr_t rootInvalid = UINT64_C(0x700000000);
    constexpr uintptr_t ownerInvalid = UINT64_C(0x700001000);
    constexpr uintptr_t holderInvalid = UINT64_C(0x700002000);
    constexpr uintptr_t cameraInvalid = UINT64_C(0x7FFFFFFFFFF0);
    StoreValue(rootSlot, rootInvalid);
    StoreValue(rootInvalid + 0xB8, ownerInvalid);
    StoreValue(ownerInvalid, holderInvalid);
    StoreValue(holderInvalid + 0x8, cameraInvalid);
    gMatrixAddressCache.nextProbe = 0;
    assert(!KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixChainStage == KoiMatrixChainStageMatrixAddress);
    assert(gTerminalChangeResetCount == 2);

    StoreValue(rootSlot, rootB);
    gMatrixAddressCache.nextProbe = 0;
    assert(KoiProjectionRefresh(unity, 1920, 1080, &projection));
    assert(projection.matrixAddress == matrixB);
    // The failed range check cleared the cached terminal, so recovery from it
    // is an initial resolution rather than another live-terminal transition.
    assert(gTerminalChangeResetCount == 2);

    // AX 0x10080595c..0x10080596c caches a failed chain probe for 50 ms.
    constexpr uintptr_t failedUnity = UINT64_C(0x500000000);
    constexpr uintptr_t failedRootSlot =
        failedUnity + UINT64_C(0x12CA9580);
    gMatrixAddressCache = {};
    gMemory.erase(failedRootSlot);
    const size_t beforeFailure = gReadCount;
    assert(!KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    assert(projection.matrixChainStage == KoiMatrixChainStageRootSlotRead);
    assert(gReadCount == beforeFailure + 1);

    constexpr uintptr_t recoveredRoot = UINT64_C(0x600000000);
    constexpr uintptr_t recoveredOwner = UINT64_C(0x600001000);
    constexpr uintptr_t recoveredHolder = UINT64_C(0x600002000);
    constexpr uintptr_t recoveredCamera = UINT64_C(0x600003000);
    constexpr uintptr_t recoveredMatrix = recoveredCamera + 0x128;
    StoreValue(failedRootSlot, recoveredRoot);
    StoreValue(recoveredRoot + 0xB8, recoveredOwner);
    StoreValue(recoveredOwner, recoveredHolder);
    StoreValue(recoveredHolder + 0x8, recoveredCamera);
    StoreMatrix(recoveredMatrix, 1.0f, 1.0f);
    gMatrixAddressCache.nextProbe = UINT64_MAX;
    const size_t beforeFailureCacheHit = gReadCount;
    assert(!KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    assert(gReadCount == beforeFailureCacheHit);
    assert(projection.matrixChainStage == KoiMatrixChainStageRootSlotRead);
    assert(projection.matrixRootSlotAddress == failedRootSlot);

    gMatrixAddressCache.nextProbe = 0;
    assert(KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    assert(projection.matrixAddress == recoveredMatrix);

    // AX 0x100805938..0x10080599c resets the world only when a previously
    // ready matrix becomes unreadable or fails the m[0]/m[10] probe.
    const size_t beforeReadyReadFailure = gTerminalChangeResetCount;
    gMemory.erase(recoveredMatrix);
    gMatrixAddressCache.nextProbe = UINT64_MAX;
    assert(!KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    assert(projection.matrixChainStage == KoiMatrixChainStageMatrixRead);
    assert(gTerminalChangeResetCount == beforeReadyReadFailure + 1);

    StoreMatrix(recoveredMatrix, 1.0f, 1.0f);
    gMatrixAddressCache.nextProbe = 0;
    assert(KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    const size_t beforeReadyZeroProbe = gTerminalChangeResetCount;
    StoreMatrix(recoveredMatrix, 0.0f, 0.0f);
    gMatrixAddressCache.nextProbe = UINT64_MAX;
    assert(!KoiProjectionRefresh(failedUnity, 1920, 1080, &projection));
    assert(projection.matrixChainStage == KoiMatrixChainStageMatrixInvalid);
    assert(gTerminalChangeResetCount == beforeReadyZeroProbe + 1);

    // An initially invalid matrix never had b551 ready and must not reset.
    constexpr uintptr_t initialInvalidUnity = UINT64_C(0x710000000);
    constexpr uintptr_t initialInvalidSlot =
        initialInvalidUnity + UINT64_C(0x12CA9580);
    constexpr uintptr_t initialInvalidRoot = UINT64_C(0x720000000);
    constexpr uintptr_t initialInvalidOwner = UINT64_C(0x720001000);
    constexpr uintptr_t initialInvalidHolder = UINT64_C(0x720002000);
    constexpr uintptr_t initialInvalidCamera = UINT64_C(0x720003000);
    constexpr uintptr_t initialInvalidMatrix = initialInvalidCamera + 0x128;
    StoreValue(initialInvalidSlot, initialInvalidRoot);
    StoreValue(initialInvalidRoot + 0xB8, initialInvalidOwner);
    StoreValue(initialInvalidOwner, initialInvalidHolder);
    StoreValue(initialInvalidHolder + 0x8, initialInvalidCamera);
    StoreMatrix(initialInvalidMatrix, 0.0f, 0.0f);
    const size_t beforeInitiallyInvalid = gTerminalChangeResetCount;
    assert(!KoiProjectionRefresh(
        initialInvalidUnity, 1920, 1080, &projection));
    assert(gTerminalChangeResetCount == beforeInitiallyInvalid);
}
