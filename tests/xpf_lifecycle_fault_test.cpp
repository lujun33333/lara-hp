#include <cassert>
#include <cstddef>
#include <vector>

#define XPF_LAYOUT_ONLY 1
#include "../vendor/XPF/src/xpf.h"

enum class FaultStage {
    Open,
    MmapAfterFstat,
    DecompressToFat,
    Fat,
    MachO,
    SectionToBase,
    Entry,
    Version,
    Dictionary,
    None,
};

enum class CleanupEvent {
    Map,
    Decompressed,
    Fd,
    Sections,
    Container,
    Strings,
    Items,
    Reset,
};

struct ModelState {
    bool mapped;
    bool decompressed;
    bool fd;
    bool sections;
    bool container;
    bool strings;
    bool items;
};

static FaultStage gFault;
static ModelState gState;
static std::vector<CleanupEvent> gEvents;
static int gStopCalls;
static int gUnreachableLocalContainers;
static const char *gError;

int xpf_start_with_kernel_path(const char *)
{
    if (gFault == FaultStage::Open) {
        gError = "open";
        return -1;
    }

    gState.fd = true;
    // AX does not branch on fstat.  Its first post-fstat failure is mmap.
    if (gFault == FaultStage::MmapAfterFstat) {
        gState.mapped = true; // MAP_FAILED is non-null and reaches munmap.
        gError = "mmap";
        return -1;
    }

    gState.mapped = true;
    if (gFault == FaultStage::DecompressToFat) {
        gError = "fat-after-decompress";
        return -1;
    }

    gState.decompressed = true;
    if (gFault == FaultStage::Fat) {
        gError = "fat";
        return -1;
    }

    // The Fat candidate is still local until one ARM64 slice succeeds.
    if (gFault == FaultStage::MachO) {
        ++gUnreachableLocalContainers;
        gError = "macho";
        return -1;
    }

    gState.container = true;
    gState.sections = true;
    if (gFault == FaultStage::SectionToBase) {
        gError = "base";
        return -1;
    }
    if (gFault == FaultStage::Entry) {
        gError = "entry";
        return -1;
    }
    if (gFault == FaultStage::Version) {
        gError = "version";
        return -1;
    }

    gState.strings = true;
    gState.items = true;
    return 0;
}

void xpf_stop(void)
{
    ++gStopCalls;
    if (gState.mapped) gEvents.push_back(CleanupEvent::Map);
    if (gState.decompressed) gEvents.push_back(CleanupEvent::Decompressed);
    if (gState.fd) gEvents.push_back(CleanupEvent::Fd);
    if (gState.sections) gEvents.push_back(CleanupEvent::Sections);
    if (gState.container) gEvents.push_back(CleanupEvent::Container);
    if (gState.strings) gEvents.push_back(CleanupEvent::Strings);
    if (gState.items) gEvents.push_back(CleanupEvent::Items);
    gEvents.push_back(CleanupEvent::Reset);
    gState = {};
    // AX deliberately keeps the last error outside gXPF across stop.
}

static void reset_model(FaultStage fault)
{
    gFault = fault;
    gState = {};
    gEvents.clear();
    gStopCalls = 0;
    gUnreachableLocalContainers = 0;
    gError = nullptr;
}

static bool state_is_clear()
{
    return !gState.mapped && !gState.decompressed && !gState.fd &&
           !gState.sections && !gState.container && !gState.strings &&
           !gState.items;
}

static void check_start_failure(FaultStage stage)
{
    reset_model(stage);
    assert(xpf_start_with_kernel_path_cleanup_on_failure("kernelcache") == -1);
    assert(gStopCalls == 1);
    assert(state_is_clear());
    assert(!gEvents.empty() && gEvents.back() == CleanupEvent::Reset);
    assert(gError != nullptr);
}

int main()
{
    check_start_failure(FaultStage::Open);
    check_start_failure(FaultStage::MmapAfterFstat);
    check_start_failure(FaultStage::DecompressToFat);
    check_start_failure(FaultStage::Fat);

    check_start_failure(FaultStage::MachO);
    assert(gUnreachableLocalContainers == 1); // Exact AX ownership boundary.

    check_start_failure(FaultStage::SectionToBase);
    check_start_failure(FaultStage::Entry);
    check_start_failure(FaultStage::Version);

    // Dictionary construction happens after a successful start, so its caller
    // owns the matching stop rather than the start helper.
    reset_model(FaultStage::Dictionary);
    assert(xpf_start_with_kernel_path_cleanup_on_failure("kernelcache") == 0);
    assert(gStopCalls == 0);
    xpf_stop();
    assert(gStopCalls == 1 && state_is_clear());

    // start -> stop -> start must rebuild items and all owned resources.
    reset_model(FaultStage::None);
    assert(xpf_start_with_kernel_path_cleanup_on_failure("kernelcache") == 0);
    assert(gState.items);
    xpf_stop();
    assert(state_is_clear());
    assert(xpf_start_with_kernel_path_cleanup_on_failure("kernelcache") == 0);
    assert(gState.items);
    xpf_stop();
    assert(gStopCalls == 2 && state_is_clear());
    return 0;
}
