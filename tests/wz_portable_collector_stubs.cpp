#include "../lara/kexploit/wz/KoiProjection.h"

#include <cstdint>
#include <cstring>

struct mach_header;

extern "C" uint64_t wz_test_read_cache_invalidation_count = 0;
extern "C" uint64_t wz_test_projection_invalidation_count = 0;

extern "C" uint32_t _dyld_image_count(void) { return 0; }
extern "C" const char *_dyld_get_image_name(uint32_t) { return nullptr; }
extern "C" const mach_header *_dyld_get_image_header(uint32_t) {
    return nullptr;
}

extern "C" void KoiProjectionReset(KoiProjectionState *state) {
    std::memset(state, 0, sizeof(*state));
}
extern "C" bool KoiProjectionRefresh(uintptr_t, uint32_t, uint32_t,
                                      KoiProjectionState *) {
    return false;
}
extern "C" void KoiProjectionInvalidateAddressCache(void) {
    ++wz_test_projection_invalidation_count;
}
extern "C" bool KoiProjectionMatrixLooksValid(const float *) { return true; }
extern "C" bool KoiProjectionWorldToScreen(const KoiProjectionState *,
    float, float, float, float *, float *, float *) { return false; }
extern "C" bool KoiProjectionMinimapPoint(float, float, float, float, float,
    float *, float *) { return false; }
extern "C" void wz_invalidate_read_cache(void) {
    ++wz_test_read_cache_invalidation_count;
}
