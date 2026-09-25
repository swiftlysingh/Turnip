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

/// Like `documentkit_inspect`, with an optional zero-based page selection and
/// UTF-8 password. `has_page_selection` distinguishes all pages from an empty
/// (invalid) selection. The option buffers are borrowed only for this call.
DocumentKitBuffer documentkit_inspect_with_options(
    const uint8_t *bytes,
    size_t length,
    const uint32_t *page_indexes,
    size_t page_count,
    int32_t has_page_selection,
    const uint8_t *password,
    size_t password_length,
    int32_t has_password
);

/// `bytes` must point to `length` readable bytes for the duration of this call.
/// Returns an owned, length-delimited UTF-8 JSON response. It is not guaranteed
/// to be NUL-terminated. Release it with
/// `documentkit_buffer_free`.
DocumentKitBuffer documentkit_extract(const uint8_t *bytes, size_t length);

/// Like `documentkit_extract`, with an optional zero-based page selection and
/// UTF-8 password. The option buffers are borrowed only for this call.
DocumentKitBuffer documentkit_extract_with_options(
    const uint8_t *bytes,
    size_t length,
    const uint32_t *page_indexes,
    size_t page_count,
    int32_t has_page_selection,
    const uint8_t *password,
    size_t password_length,
    int32_t has_password
);

/// Extracts a structured, source-preserving document using the same local PDF
/// pipeline as `documentkit_extract`. The JSON response has bridge schema 3
/// and carries a `document` payload with page-local blocks, lines, and tables.
DocumentKitBuffer documentkit_extract_document(const uint8_t *bytes, size_t length);

/// Like `documentkit_extract_document`, with an optional zero-based page
/// selection and UTF-8 password. The option buffers are borrowed only for this
/// call. Requested pages remain in original document order in the result.
DocumentKitBuffer documentkit_extract_document_with_options(
    const uint8_t *bytes,
    size_t length,
    const uint32_t *page_indexes,
    size_t page_count,
    int32_t has_page_selection,
    const uint8_t *password,
    size_t password_length,
    int32_t has_password
);

/// Releases a buffer returned by DocumentKitCore. Accepts an empty buffer.
void documentkit_buffer_free(DocumentKitBuffer buffer);

/// Returns a process-lifetime UTF-8 string. Do not free it.
const char *documentkit_engine_version(void);

/// Returns the process-lifetime Git revision of the packaged engine. Do not free it.
const char *documentkit_engine_revision(void);

#ifdef __cplusplus
}
#endif

#endif
