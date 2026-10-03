#pragma once
#include <stdint.h>
struct mach_header;
extern "C" uint32_t _dyld_image_count(void);
extern "C" const char *_dyld_get_image_name(uint32_t);
extern "C" const struct mach_header *_dyld_get_image_header(uint32_t);
