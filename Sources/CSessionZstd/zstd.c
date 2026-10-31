#include "CSessionZstd.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>

typedef struct { const void *src; size_t size; size_t pos; } InBuffer;
typedef struct { void *dst; size_t size; size_t pos; } OutBuffer;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void *library;
static void *(*create_stream)(void);
static size_t (*free_stream)(void *);
static size_t (*decode_stream)(void *, OutBuffer *, InBuffer *);
static unsigned (*is_error)(size_t);

static void load_library(void) {
    const char *paths[] = {
        "/opt/homebrew/opt/zstd/lib/libzstd.dylib",
        "/usr/local/opt/zstd/lib/libzstd.dylib",
        "/usr/lib/libzstd.dylib"
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        library = dlopen(paths[i], RTLD_LOCAL | RTLD_NOW);
        if (library) break;
    }
    if (!library) return;
    create_stream = dlsym(library, "ZSTD_createDStream");
    free_stream = dlsym(library, "ZSTD_freeDStream");
    decode_stream = dlsym(library, "ZSTD_decompressStream");
    is_error = dlsym(library, "ZSTD_isError");
    if (!create_stream || !free_stream || !decode_stream || !is_error) {
        dlclose(library);
        library = NULL;
    }
}

int dsh_zstd_decode(const uint8_t *input, size_t count, uint8_t **output, size_t *output_count) {
    pthread_once(&once, load_library);
    *output = NULL;
    *output_count = 0;
    if (!library) return -1;
    void *stream = create_stream();
    if (!stream) return -3;
    size_t capacity = 65536;
    uint8_t *bytes = malloc(capacity);
    if (!bytes) { free_stream(stream); return -3; }
    InBuffer source = { input, count, 0 };
    size_t used = 0;
    int result = -2;
    for (;;) {
        if (used == capacity) {
            /* shortcut: frames are capped at 512 MiB, add streaming output if real logs exceed it. */
            if (capacity >= 512 * 1024 * 1024) { result = -3; break; }
            capacity *= 2;
            uint8_t *grown = realloc(bytes, capacity);
            if (!grown) { result = -3; break; }
            bytes = grown;
        }
        OutBuffer destination = { bytes + used, capacity - used, 0 };
        size_t previous = source.pos;
        size_t remaining = decode_stream(stream, &destination, &source);
        used += destination.pos;
        if (is_error(remaining)) break;
        if (remaining == 0 && source.pos == count) { result = 0; break; }
        if (source.pos == previous && destination.pos == 0) break;
    }
    free_stream(stream);
    if (result != 0) { free(bytes); return result; }
    *output = bytes;
    *output_count = used;
    return 0;
}

void dsh_zstd_free(void *output) { free(output); }
