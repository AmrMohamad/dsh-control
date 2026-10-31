#include <stddef.h>
#include <stdint.h>

/* Decode a complete frame using an installed libzstd. Caller frees output. */
int dsh_zstd_decode(const uint8_t *input, size_t count, uint8_t **output, size_t *output_count);
void dsh_zstd_free(void *output);
