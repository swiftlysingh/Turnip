#ifndef DOCUMENTKIT_CORE_H
#define DOCUMENTKIT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    size_t length;
} DocumentKitBuffer;

/// `bytes` must point to `length` readable bytes for the duration of this call.
/// Returns an owned, length-delimited UTF-8 JSON response. It is not guaranteed
/// to be NUL-terminated. Release it with
/// `documentkit_buffer_free`.
DocumentKitBuffer documentkit_inspect(const uint8_t *bytes, size_t length);

/// `bytes` must point to `length` readable bytes for the duration of this call.
/// Returns an owned, length-delimited UTF-8 JSON response. It is not guaranteed
/// to be NUL-terminated. Release it with
/// `documentkit_buffer_free`.
DocumentKitBuffer documentkit_extract(const uint8_t *bytes, size_t length);

/// Releases a buffer returned by DocumentKitCore. Accepts an empty buffer.
void documentkit_buffer_free(DocumentKitBuffer buffer);

/// Returns a process-lifetime UTF-8 string. Do not free it.
const char *documentkit_engine_version(void);

#ifdef __cplusplus
}
#endif

#endif
