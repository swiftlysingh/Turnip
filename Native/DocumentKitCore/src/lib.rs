use pdf_inspector::{
    DetectionConfig, PdfError, PdfOptions, PdfProcessResult, PdfType, ScanStrategy,
};
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
    #[serde(skip_serializing_if = "Option::is_none")]
    page_index: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    page_count: Option<u32>,
}

enum Operation {
    Inspect,
    Extract,
}

#[derive(Default)]
struct ProcessingOptions {
    page_indexes: Option<Vec<u32>>,
    password: Option<String>,
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
    process(
        bytes,
        length,
        Operation::Inspect,
        ProcessingOptions::default(),
    )
}

/// # Safety
///
/// The PDF and option pointers must remain readable for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_inspect_with_options(
    bytes: *const u8,
    length: usize,
    page_indexes: *const u32,
    page_count: usize,
    has_page_selection: i32,
    password: *const u8,
    password_length: usize,
    has_password: i32,
) -> DocumentKitBuffer {
    process_with_options(
        bytes,
        length,
        Operation::Inspect,
        page_indexes,
        page_count,
        has_page_selection,
        password,
        password_length,
        has_password,
    )
}

/// # Safety
///
/// `bytes` must point to `length` readable bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_extract(bytes: *const u8, length: usize) -> DocumentKitBuffer {
    process(
        bytes,
        length,
        Operation::Extract,
        ProcessingOptions::default(),
    )
}

/// # Safety
///
/// The PDF and option pointers must remain readable for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_extract_with_options(
    bytes: *const u8,
    length: usize,
    page_indexes: *const u32,
    page_count: usize,
    has_page_selection: i32,
    password: *const u8,
    password_length: usize,
    has_password: i32,
) -> DocumentKitBuffer {
    process_with_options(
        bytes,
        length,
        Operation::Extract,
        page_indexes,
        page_count,
        has_page_selection,
        password,
        password_length,
        has_password,
    )
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

#[allow(clippy::too_many_arguments)]
unsafe fn process_with_options(
    bytes: *const u8,
    length: usize,
    operation: Operation,
    page_indexes: *const u32,
    page_count: usize,
    has_page_selection: i32,
    password: *const u8,
    password_length: usize,
    has_password: i32,
) -> DocumentKitBuffer {
    let options = parse_options(
        page_indexes,
        page_count,
        has_page_selection,
        password,
        password_length,
        has_password,
    );
    match options {
        Ok(options) => process(bytes, length, operation, options),
        Err(error) => encode_response(Response {
            schema_version: 1,
            ok: false,
            result: None,
            error: Some(error),
        }),
    }
}

unsafe fn parse_options(
    page_indexes: *const u32,
    page_count: usize,
    has_page_selection: i32,
    password: *const u8,
    password_length: usize,
    has_password: i32,
) -> Result<ProcessingOptions, ErrorPayload> {
    let page_indexes = if has_page_selection != 0 {
        if page_count == 0 {
            return Err(option_error(
                "empty_page_selection",
                "At least one page must be selected",
            ));
        }
        if page_indexes.is_null() {
            return Err(option_error(
                "invalid_options",
                "The page selection pointer is null",
            ));
        }
        let pages = slice::from_raw_parts(page_indexes, page_count).to_vec();
        if pages.windows(2).any(|pair| pair[0] >= pair[1]) {
            return Err(option_error(
                "invalid_page_order",
                "Page indexes must be unique and strictly ascending",
            ));
        }
        Some(pages)
    } else {
        None
    };

    let password = if has_password != 0 {
        if password_length > 0 && password.is_null() {
            return Err(option_error(
                "invalid_options",
                "The password pointer is null",
            ));
        }
        let bytes = if password_length == 0 {
            &[]
        } else {
            slice::from_raw_parts(password, password_length)
        };
        Some(
            std::str::from_utf8(bytes)
                .map_err(|_| {
                    option_error(
                        "invalid_password_encoding",
                        "The password is not valid UTF-8",
                    )
                })?
                .to_owned(),
        )
    } else {
        None
    };

    Ok(ProcessingOptions {
        page_indexes,
        password,
    })
}

fn option_error(code: &'static str, message: &'static str) -> ErrorPayload {
    ErrorPayload {
        code,
        message: message.to_string(),
        page_index: None,
        page_count: None,
    }
}

unsafe fn process(
    bytes: *const u8,
    length: usize,
    operation: Operation,
    processing_options: ProcessingOptions,
) -> DocumentKitBuffer {
    let response = catch_unwind(AssertUnwindSafe(|| {
        validate_input(bytes, length)?;
        let data = slice::from_raw_parts(bytes, length);
        let selected_pages: Option<Vec<u32>> = processing_options
            .page_indexes
            .as_ref()
            .map(|pages| {
                pages
                    .iter()
                    .map(|page| {
                        page.checked_add(1).ok_or_else(|| ErrorPayload {
                            code: "invalid_page_index",
                            message: format!("Page index {page} exceeds the supported range"),
                            page_index: Some(*page),
                            page_count: None,
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()
            })
            .transpose()?;
        let mut options = match operation {
            Operation::Inspect => PdfOptions::detect_only(),
            Operation::Extract => PdfOptions::new(),
        };
        if let Some(pages) = selected_pages.as_ref() {
            options.page_filter = Some(pages.iter().copied().collect());
            options.detection = DetectionConfig {
                strategy: ScanStrategy::Pages(pages.clone()),
                ..DetectionConfig::default()
            };
        }
        options.password = processing_options.password;

        let result =
            pdf_inspector::process_pdf_mem_with_options(data, options).map_err(error_payload)?;

        Ok(result_payload(
            result,
            processing_options.page_indexes.as_deref(),
        ))
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
                page_index: None,
                page_count: None,
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
            page_index: None,
            page_count: None,
        });
    }
    if length == 0 {
        return Err(ErrorPayload {
            code: "empty_input",
            message: "The PDF data is empty".to_string(),
            page_index: None,
            page_count: None,
        });
    }
    if length > MAX_INPUT_BYTES {
        return Err(ErrorPayload {
            code: "input_too_large",
            message: format!(
                "The PDF exceeds the {} MiB limit",
                MAX_INPUT_BYTES / 1024 / 1024
            ),
            page_index: None,
            page_count: None,
        });
    }
    Ok(())
}

fn result_payload(result: PdfProcessResult, selected_pages: Option<&[u32]>) -> ResultPayload {
    let selected = |page: u32| selected_pages.is_none_or(|pages| pages.contains(&page));
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
        pages_needing_ocr: zero_based_pages(
            result
                .pages_needing_ocr
                .into_iter()
                .filter(|page| page.checked_sub(1).is_some_and(selected))
                .collect(),
        ),
        ocr_reasons_by_page: result
            .ocr_reasons_by_page
            .into_iter()
            .filter_map(|entry| {
                let page = entry.page.checked_sub(1)?;
                selected(page).then_some(OcrReasonsPayload {
                    page,
                    reasons: entry.reasons,
                })
            })
            .collect(),
        title: result.title,
        confidence: result.confidence,
        is_complex: result.layout.is_complex,
        pages_with_tables: zero_based_pages(
            result
                .layout
                .pages_with_tables
                .into_iter()
                .filter(|page| page.checked_sub(1).is_some_and(selected))
                .collect(),
        ),
        pages_with_columns: zero_based_pages(
            result
                .layout
                .pages_with_columns
                .into_iter()
                .filter(|page| page.checked_sub(1).is_some_and(selected))
                .collect(),
        ),
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
    match error {
        PdfError::PageOutOfRange { page, page_count } => ErrorPayload {
            code: "page_out_of_range",
            message: format!(
                "Page index {} is outside the PDF's {page_count} pages",
                page.saturating_sub(1)
            ),
            page_index: Some(page.saturating_sub(1)),
            page_count: Some(page_count),
        },
        error => {
            let code = match error {
                PdfError::Io(_) => "io_error",
                PdfError::Parse(_) => "parse_error",
                PdfError::Encrypted => "encrypted_pdf",
                PdfError::InvalidStructure => "invalid_structure",
                PdfError::NotAPdf(_) => "not_a_pdf",
                PdfError::PageOutOfRange { .. } => unreachable!(),
            };
            ErrorPayload {
                code,
                message: error.to_string(),
                page_index: None,
                page_count: None,
            }
        }
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

    #[test]
    fn empty_selected_pages_returns_typed_error() {
        let bytes = b"%PDF-1.4";
        let value = unsafe {
            documentkit_inspect_with_options(
                bytes.as_ptr(),
                bytes.len(),
                std::ptr::null(),
                0,
                1,
                std::ptr::null(),
                0,
                0,
            )
        };
        let json = std::str::from_utf8(unsafe { slice::from_raw_parts(value.data, value.length) })
            .unwrap();
        assert!(json.contains(r#""code":"empty_page_selection""#));
        unsafe { documentkit_buffer_free(value) };
    }

    #[test]
    fn password_never_appears_in_error_response() {
        let bytes = b"definitely not a PDF";
        let password = b"top-secret";
        let value = unsafe {
            documentkit_extract_with_options(
                bytes.as_ptr(),
                bytes.len(),
                std::ptr::null(),
                0,
                0,
                password.as_ptr(),
                password.len(),
                1,
            )
        };
        let json = std::str::from_utf8(unsafe { slice::from_raw_parts(value.data, value.length) })
            .unwrap();
        assert!(!json.contains("top-secret"));
        unsafe { documentkit_buffer_free(value) };
    }
}
