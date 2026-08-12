use pdf_inspector::{PdfError, PdfProcessResult, PdfType};
use serde::Serialize;
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

const PDF_INSPECTOR_VERSION: &str = "1.14.1";
const MAX_INPUT_BYTES: usize = 100 * 1024 * 1024;
const VERSION: &CStr = c"pdf-inspector/1.14.1";

#[derive(Serialize)]
struct Response {
    schema_version: u32,
    ok: bool,
    result: Option<ResultPayload>,
    error: Option<ErrorPayload>,
}

#[derive(Serialize)]
struct ResultPayload {
    engine_version: &'static str,
    pdf_type: &'static str,
    markdown: Option<String>,
    page_count: u32,
    processing_time_ms: u64,
    pages_needing_ocr: Vec<u32>,
    ocr_reasons_by_page: Vec<OcrReasonsPayload>,
    title: Option<String>,
    confidence: f32,
    is_complex: bool,
    pages_with_tables: Vec<u32>,
    pages_with_columns: Vec<u32>,
    has_encoding_issues: bool,
}

#[derive(Serialize)]
struct OcrReasonsPayload {
    page: u32,
    reasons: Vec<String>,
}

#[derive(Serialize)]
struct ErrorPayload {
    code: &'static str,
    message: String,
}

enum Operation {
    Inspect,
    Extract,
}

#[repr(C)]
pub struct DocumentKitBuffer {
    data: *mut u8,
    length: usize,
}

/// # Safety
///
/// `bytes` must point to `length` readable bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_inspect(bytes: *const u8, length: usize) -> DocumentKitBuffer {
    process(bytes, length, Operation::Inspect)
}

/// # Safety
///
/// `bytes` must point to `length` readable bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_extract(bytes: *const u8, length: usize) -> DocumentKitBuffer {
    process(bytes, length, Operation::Extract)
}

/// # Safety
///
/// `buffer` must have been returned by this library and not already freed.
#[no_mangle]
pub unsafe extern "C" fn documentkit_buffer_free(buffer: DocumentKitBuffer) {
    if !buffer.data.is_null() && buffer.length > 0 {
        let slice = std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.length);
        drop(Box::from_raw(slice));
    }
}

#[no_mangle]
pub extern "C" fn documentkit_engine_version() -> *const c_char {
    VERSION.as_ptr()
}

unsafe fn process(bytes: *const u8, length: usize, operation: Operation) -> DocumentKitBuffer {
    let response = catch_unwind(AssertUnwindSafe(|| {
        validate_input(bytes, length)?;
        let data = slice::from_raw_parts(bytes, length);
        let result = match operation {
            Operation::Inspect => pdf_inspector::detect_pdf_mem(data),
            Operation::Extract => pdf_inspector::process_pdf_mem(data),
        }
        .map_err(error_payload)?;

        Ok(result_payload(result))
    }));

    let response = match response {
        Ok(Ok(result)) => Response {
            schema_version: 1,
            ok: true,
            result: Some(result),
            error: None,
        },
        Ok(Err(error)) => Response {
            schema_version: 1,
            ok: false,
            result: None,
            error: Some(error),
        },
        Err(_) => Response {
            schema_version: 1,
            ok: false,
            result: None,
            error: Some(ErrorPayload {
                code: "engine_panic",
                message: "The PDF engine stopped unexpectedly".to_string(),
            }),
        },
    };

    encode_response(response)
}

fn validate_input(bytes: *const u8, length: usize) -> Result<(), ErrorPayload> {
    if bytes.is_null() {
        return Err(ErrorPayload {
            code: "invalid_input",
            message: "The PDF data pointer is null".to_string(),
        });
    }
    if length == 0 {
        return Err(ErrorPayload {
            code: "empty_input",
            message: "The PDF data is empty".to_string(),
        });
    }
    if length > MAX_INPUT_BYTES {
        return Err(ErrorPayload {
            code: "input_too_large",
            message: format!(
                "The PDF exceeds the {} MiB limit",
                MAX_INPUT_BYTES / 1024 / 1024
            ),
        });
    }
    Ok(())
}

fn result_payload(result: PdfProcessResult) -> ResultPayload {
    ResultPayload {
        engine_version: PDF_INSPECTOR_VERSION,
        pdf_type: match result.pdf_type {
            PdfType::TextBased => "text_based",
            PdfType::Scanned => "scanned",
            PdfType::ImageBased => "image_based",
            PdfType::Mixed => "mixed",
        },
        markdown: result.markdown,
        page_count: result.page_count,
        processing_time_ms: result.processing_time_ms,
        pages_needing_ocr: zero_based_pages(result.pages_needing_ocr),
        ocr_reasons_by_page: result
            .ocr_reasons_by_page
            .into_iter()
            .map(|entry| OcrReasonsPayload {
                page: entry.page.saturating_sub(1),
                reasons: entry.reasons,
            })
            .collect(),
        title: result.title,
        confidence: result.confidence,
        is_complex: result.layout.is_complex,
        pages_with_tables: zero_based_pages(result.layout.pages_with_tables),
        pages_with_columns: zero_based_pages(result.layout.pages_with_columns),
        has_encoding_issues: result.has_encoding_issues,
    }
}

fn zero_based_pages(pages: Vec<u32>) -> Vec<u32> {
    pages
        .into_iter()
        .map(|page| page.saturating_sub(1))
        .collect()
}

fn error_payload(error: PdfError) -> ErrorPayload {
    let code = match error {
        PdfError::Io(_) => "io_error",
        PdfError::Parse(_) => "parse_error",
        PdfError::Encrypted => "encrypted_pdf",
        PdfError::InvalidStructure => "invalid_structure",
        PdfError::NotAPdf(_) => "not_a_pdf",
    };
    ErrorPayload {
        code,
        message: error.to_string(),
    }
}

fn encode_response(response: Response) -> DocumentKitBuffer {
    let json = serde_json::to_vec(&response).unwrap_or_else(|_| {
        br#"{"schema_version":1,"ok":false,"result":null,"error":{"code":"serialization_error","message":"Could not encode the engine response"}}"#.to_vec()
    });
    let mut bytes = json.into_boxed_slice();
    let buffer = DocumentKitBuffer {
        data: bytes.as_mut_ptr(),
        length: bytes.len(),
    };
    std::mem::forget(bytes);
    buffer
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_returns_typed_error() {
        let value = unsafe { documentkit_extract([0_u8].as_ptr(), 0) };
        assert!(!value.data.is_null());
        let json = std::str::from_utf8(unsafe { slice::from_raw_parts(value.data, value.length) })
            .unwrap();
        assert!(json.contains(r#""code":"empty_input""#));
        unsafe { documentkit_buffer_free(value) };
    }

    #[test]
    fn non_pdf_returns_typed_error() {
        let bytes = b"definitely not a PDF";
        let value = unsafe { documentkit_inspect(bytes.as_ptr(), bytes.len()) };
        assert!(!value.data.is_null());
        let json = std::str::from_utf8(unsafe { slice::from_raw_parts(value.data, value.length) })
            .unwrap();
        assert!(json.contains(r#""code":"not_a_pdf""#));
        unsafe { documentkit_buffer_free(value) };
    }
}
