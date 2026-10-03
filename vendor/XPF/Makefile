CC = clang
LDID ?= ldid

CHOMA_DYLIB_PATH ?= 0
CHOMA_PATH       ?= external/ChOma
OUTPUT_ROOT      ?= output
CFLAGS            = -O2 -framework Foundation -I$(CHOMA_PATH)/include
CFLAGS_MACOS      = $(CFLAGS)
CFLAGS_IOS        = $(CFLAGS) -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -arch arm64 -arch arm64e
LDFLAGS           = -lcompression

XPF_SOURCES = src/bad_recovery.c src/common.c src/decompress.c src/non_ppl.c src/ppl.c src/xpf.c

all: $(OUTPUT_ROOT)/macos/libxpf.dylib $(OUTPUT_ROOT)/ios/libxpf.dylib $(OUTPUT_ROOT)/macos/xpf_test $(OUTPUT_ROOT)/ios/xpf_test

ifneq ($(CHOMA_DYLIB_PATH), 0)
CHOMA_DEP = 
LDFLAGS  += -L$(CHOMA_DYLIB_PATH) -lchoma
else
CHOMA_DEP = $(CHOMA_PATH)/src/*.c
endif

$(OUTPUT_ROOT)/macos/libxpf.dylib: $(XPF_SOURCES) $(CHOMA_DEP)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_MACOS) $(LDFLAGS) -dynamiclib -install_name @loader_path/libxpf.dylib -o $@ $^

$(OUTPUT_ROOT)/ios/libxpf.dylib: $(XPF_SOURCES) $(CHOMA_DEP)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_IOS) $(LDFLAGS) -dynamiclib -install_name @executable_path/Frameworks/libxpf.dylib -o $@ $^
	$(LDID) -S $@

$(OUTPUT_ROOT)/macos/xpf_test: $(wildcard src/cli/*.c)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_MACOS) $(LDFLAGS) -L$(shell dirname $@) -lxpf -o $@ $^

$(OUTPUT_ROOT)/ios/xpf_test: $(wildcard src/cli/*.c)
	@mkdir -p $(shell dirname $@)
	$(CC) $(CFLAGS_IOS) $(LDFLAGS) -L$(shell dirname $@) -lxpf -o $@ $^
	@$(LDID) -S $@

clean:
	@rm -rf $(OUTPUT_ROOT)
