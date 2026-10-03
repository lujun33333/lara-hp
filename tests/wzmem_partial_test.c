#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "wzmem_partial.h"

typedef struct {
    int calls;
    int failCall;
    size_t partialOnFailure;
    size_t pageSize;
} fake_reader_t;

static int fake_read(void *opaque, uint64_t address, void *buffer, size_t size,
                     size_t *completed) {
    fake_reader_t *reader = (fake_reader_t *)opaque;
    ++reader->calls;
    assert(size > 0);
    assert((address % reader->pageSize) + size <= reader->pageSize);
    memset(buffer, reader->calls, size);
    if (reader->calls == reader->failCall) {
        *completed = reader->partialOnFailure < size
            ? reader->partialOnFailure : size;
        return -1;
    }
    *completed = size;
    return 0;
}

int main(void) {
    uint8_t bytes[64] = {0};
    fake_reader_t reader = {.pageSize = 16};

    long result = wzmem_read_chunks(8, bytes, 32, 16, fake_read, &reader);
    assert(result == 32 && reader.calls == 3);
    assert(bytes[0] == 1 && bytes[8] == 2 && bytes[24] == 3);

    memset(bytes, 0, sizeof(bytes));
    reader = (fake_reader_t){.failCall = 2, .pageSize = 16};
    result = wzmem_read_chunks(8, bytes, 32, 16, fake_read, &reader);
    assert(result == 8 && reader.calls == 2);

    memset(bytes, 0, sizeof(bytes));
    reader = (fake_reader_t){.failCall = 2, .partialOnFailure = 3, .pageSize = 16};
    result = wzmem_read_chunks(8, bytes, 32, 16, fake_read, &reader);
    assert(result == 11 && reader.calls == 2 && bytes[8] == 2);

    reader = (fake_reader_t){.failCall = 1, .pageSize = 16};
    assert(wzmem_read_chunks(0, bytes, 8, 16, fake_read, &reader) == -1);
    assert(wzmem_read_chunks(UINT64_MAX - 3, bytes, 8, 16, fake_read, &reader) == -1);
    assert(wzmem_read_chunks(0, NULL, 8, 16, fake_read, &reader) == -1);

    puts("PASS: full, partial, zero-byte failure, page split and overflow semantics");
    return 0;
}
