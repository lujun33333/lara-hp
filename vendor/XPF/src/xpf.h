#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#if defined(XPF_LAYOUT_ONLY)
typedef struct Fat Fat;
typedef struct MachO MachO;
typedef struct PFSection PFSection;
typedef void *xpc_object_t;
#else
#include <choma/Fat.h>
#include <choma/Util.h>
#include <choma/PatchFinder.h>
#include <choma/PatchFinder_arm64.h>
#include <choma/arm64.h>
#include <xpc/xpc.h>
#endif

typedef struct s_XPFItem {
	struct s_XPFItem *nextItem;
	const char *name;
	uint64_t (*finder)(void *);
	void *ctx;
	bool cached;
	uint64_t cache;
} XPFItem;

typedef struct s_XPFSet {
	const char *name;
	bool (*supported)(void);
	const char *metrics[];
} XPFSet;

#define XPF_ASSERT(assert) if (!(assert)) { if (!xpf_get_error()) { xpf_set_error("[%s:%d] Failed assert in %s: %s", __FILE__, __LINE__, __FUNCTION__, #assert); } return 0; }

int xpf_start_with_kernel_path(const char *kernelPath);
void xpf_item_register(const char *name, void *finder, void *ctx);
uint64_t xpf_item_resolve(const char *name);
uint64_t xpfsec_decode_pointer(PFSection *section, uint64_t vmaddr, uint64_t value);
bool xpf_set_is_supported(const char *name);
int xpf_offset_dictionary_add_set(xpc_object_t xdict, XPFSet *set);
void xpf_set_ignore_base_set(bool val);
xpc_object_t xpf_construct_offset_dictionary(const char *sets[]);
void xpf_set_error(const char *error, ...);
const char *xpf_get_error(void);
void xpf_print_all_items(void);
void xpf_stop(void);

// AX leaves partial start state in gXPF and makes the caller run xpf_stop().
// Keep that ownership rule in one inline helper so every consumer performs the
// same failure cleanup without changing the exported start routine itself.
static inline int xpf_start_with_kernel_path_cleanup_on_failure(const char *kernelPath)
{
	int result = xpf_start_with_kernel_path(kernelPath);
	if (result != 0) {
		xpf_stop();
	}
	return result;
}

typedef struct s_XPF {
	int kernelFd;
	void *mappedKernel;
	size_t kernelSize;
	void *decompressedKernel;
	size_t decompressedKernelSize;

	Fat *kernelContainer;
	MachO *kernel;
	bool kernelIsFileset;
	bool kernelIsArm64e;
	char *kernelVersionString;
	char *kernelInfoPlist;
	char *darwinVersion;
	char *xnuBuild;
	char *xnuPlatform;
	char *osVersion;

	uint64_t kernelBase;
	uint64_t kernelEntry;

	PFSection *kernelTextSection;
	PFSection *kernelPinstSection;
	PFSection *kernelPPLTextSection;
	PFSection *kernelStringSection;
	PFSection *kernelConstSection;
	PFSection *kernelDataConstSection;
	PFSection *kernelDataSection;
	PFSection *kernelOSLogSection;
	PFSection *kernelPrelinkTextSection;
	PFSection *kernelPLKTextSection;
	PFSection *kernelKmodInfoSection;
	PFSection *kernelPrelinkInfoSection;
	PFSection *kernelBootdataInit;
	PFSection *kernelAMFITextSection;
	PFSection *kernelAMFIStringSection;
	PFSection *kernelSandboxTextSection;
	PFSection *kernelSandboxStringSection;
	PFSection *kernelInfoPlistSection;

	XPFItem *firstItem;
	bool ignoreBaseSet;
} XPF;

#if defined(__cplusplus)
static_assert(offsetof(XPF, firstItem) == 0x110, "AX 1.2.8 firstItem ABI");
static_assert(offsetof(XPF, ignoreBaseSet) == 0x118, "AX 1.2.8 ignoreBaseSet ABI");
static_assert(sizeof(XPF) == 0x120, "AX 1.2.8 XPF size");
#else
_Static_assert(offsetof(XPF, firstItem) == 0x110, "AX 1.2.8 firstItem ABI");
_Static_assert(offsetof(XPF, ignoreBaseSet) == 0x118, "AX 1.2.8 ignoreBaseSet ABI");
_Static_assert(sizeof(XPF) == 0x120, "AX 1.2.8 XPF size");
#endif
extern XPF gXPF;
