use pdf_inspector::{
    DetectionConfig, PdfError, PdfOptions, PdfProcessResult, PdfType, ProcessMode, ScanStrategy,
    StructuredBlockContent, StructuredBounds, StructuredCellState, StructuredDocument,
    StructuredPageStatus,
};
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};
use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

const PDF_INSPECTOR_VERSION: &str = env!("DOCUMENTKIT_PDF_INSPECTOR_VERSION");
const MAX_INPUT_BYTES: usize = 100 * 1024 * 1024;
const BRIDGE_SCHEMA_VERSION: u32 = 3;
const VERSION: &[u8] = concat!(
    "pdf-inspector/",
    env!("DOCUMENTKIT_PDF_INSPECTOR_VERSION"),
    "\0"
)
.as_bytes();
const REVISION: &[u8] = concat!(env!("DOCUMENTKIT_PDF_INSPECTOR_REVISION"), "\0").as_bytes();

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
    #[serde(skip_serializing_if = "Option::is_none")]
    document: Option<StructuredDocument>,
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

#[derive(Clone, Copy, PartialEq, Eq)]
enum Operation {
    Inspect,
    Extract,
    ExtractDocument,
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
/// `bytes` must point to `length` readable bytes for the duration of the call.
/// The result includes source-preserving structured page, text, and table data.
#[no_mangle]
pub unsafe extern "C" fn documentkit_extract_document(
    bytes: *const u8,
    length: usize,
) -> DocumentKitBuffer {
    process(
        bytes,
        length,
        Operation::ExtractDocument,
        ProcessingOptions::default(),
    )
}

/// # Safety
///
/// The PDF and option pointers must remain readable for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn documentkit_extract_document_with_options(
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
        Operation::ExtractDocument,
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
    VERSION.as_ptr().cast()
}

#[no_mangle]
pub extern "C" fn documentkit_engine_revision() -> *const c_char {
    REVISION.as_ptr().cast()
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
            schema_version: BRIDGE_SCHEMA_VERSION,
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
            Operation::ExtractDocument => PdfOptions::new()
                .mode(ProcessMode::Analyze)
                .capture_structured_output(),
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

        result_payload(
            result,
            processing_options.page_indexes.as_deref(),
            operation,
        )
    }));

    let response = match response {
        Ok(Ok(result)) => Response {
            schema_version: BRIDGE_SCHEMA_VERSION,
            ok: true,
            result: Some(result),
            error: None,
        },
        Ok(Err(error)) => Response {
            schema_version: BRIDGE_SCHEMA_VERSION,
            ok: false,
            result: None,
            error: Some(error),
        },
        Err(_) => Response {
            schema_version: BRIDGE_SCHEMA_VERSION,
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

fn result_payload(
    result: PdfProcessResult,
    selected_pages: Option<&[u32]>,
    operation: Operation,
) -> Result<ResultPayload, ErrorPayload> {
    let selected = |page: u32| selected_pages.is_none_or(|pages| pages.contains(&page));
    let mut pages_needing_ocr = zero_based_pages(
        result
            .pages_needing_ocr
            .into_iter()
            .filter(|page| page.checked_sub(1).is_some_and(selected))
            .collect(),
    );
    pages_needing_ocr.sort_unstable();
    pages_needing_ocr.dedup();

    let document = result.structured_document;
    if operation == Operation::ExtractDocument {
        let document = document.as_ref().ok_or_else(|| {
            structured_output_error("The PDF engine omitted its structured document")
        })?;
        validate_structured_document(
            document,
            selected_pages,
            result.page_count,
            &pages_needing_ocr,
        )?;
    } else if document.is_some() {
        return Err(structured_output_error(
            "The PDF engine returned structured data for an unsupported operation",
        ));
    }

    let markdown = if operation == Operation::ExtractDocument {
        None
    } else {
        result.markdown
    };
    let mut ocr_reasons_by_page: BTreeMap<u32, Vec<String>> = BTreeMap::new();
    for entry in result.ocr_reasons_by_page {
        let Some(page) = entry.page.checked_sub(1) else {
            continue;
        };
        if !selected(page) {
            continue;
        }
        let reasons = ocr_reasons_by_page.entry(page).or_default();
        for reason in entry.reasons {
            if !reasons.contains(&reason) {
                reasons.push(reason);
            }
        }
    }
    let mut pages_with_tables = zero_based_pages(
        result
            .layout
            .pages_with_tables
            .into_iter()
            .filter(|page| page.checked_sub(1).is_some_and(selected))
            .collect(),
    );
    pages_with_tables.sort_unstable();
    pages_with_tables.dedup();
    let mut pages_with_columns = zero_based_pages(
        result
            .layout
            .pages_with_columns
            .into_iter()
            .filter(|page| page.checked_sub(1).is_some_and(selected))
            .collect(),
    );
    pages_with_columns.sort_unstable();
    pages_with_columns.dedup();

    Ok(ResultPayload {
        engine_version: PDF_INSPECTOR_VERSION,
        pdf_type: match result.pdf_type {
            PdfType::TextBased => "text_based",
            PdfType::Scanned => "scanned",
            PdfType::ImageBased => "image_based",
            PdfType::Mixed => "mixed",
        },
        markdown,
        page_count: result.page_count,
        processing_time_ms: result.processing_time_ms,
        pages_needing_ocr,
        ocr_reasons_by_page: ocr_reasons_by_page
            .into_iter()
            .map(|(page, reasons)| OcrReasonsPayload { page, reasons })
            .collect(),
        title: result.title,
        confidence: result.confidence,
        is_complex: result.layout.is_complex,
        pages_with_tables,
        pages_with_columns,
        has_encoding_issues: result.has_encoding_issues,
        document,
    })
}

fn zero_based_pages(pages: Vec<u32>) -> Vec<u32> {
    pages
        .into_iter()
        .map(|page| page.saturating_sub(1))
        .collect()
}

fn structured_output_error(message: impl Into<String>) -> ErrorPayload {
    ErrorPayload {
        code: "invalid_structured_output",
        message: message.into(),
        page_index: None,
        page_count: None,
    }
}

fn validate_structured_document(
    document: &StructuredDocument,
    selected_pages: Option<&[u32]>,
    page_count: u32,
    pages_needing_ocr: &[u32],
) -> Result<(), ErrorPayload> {
    let expected_pages: Vec<u32> = selected_pages
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| (0..page_count).collect());
    let actual_pages: Vec<u32> = document.pages.iter().map(|page| page.page_index).collect();
    if actual_pages != expected_pages {
        return Err(structured_output_error(
            "The structured document does not cover the requested pages in source order",
        ));
    }

    let actual_ocr_pages: Vec<u32> = document
        .pages
        .iter()
        .filter(|page| page.status == StructuredPageStatus::NeedsOcr)
        .map(|page| page.page_index)
        .collect();
    if actual_ocr_pages != pages_needing_ocr {
        return Err(structured_output_error(
            "The structured page statuses do not match OCR coverage",
        ));
    }

    let mut block_ids = HashSet::new();
    for page in &document.pages {
        if page.page_index >= page_count
            || !page.size.width.is_finite()
            || !page.size.height.is_finite()
            || page.size.width <= 0.0
            || page.size.height <= 0.0
        {
            return Err(structured_output_error(
                "The structured document contains an invalid page",
            ));
        }
        for (block_index, block) in page.blocks.iter().enumerate() {
            if block.id != format!("p{}-b{block_index}", page.page_index)
                || !block_ids.insert(block.id.as_str())
            {
                return Err(structured_output_error(
                    "The structured document contains invalid block identifiers",
                ));
            }
            validate_bounds(block.bounds.as_ref())?;
            match &block.content {
                StructuredBlockContent::Text { lines } => {
                    for line in lines {
                        validate_bounds(line.bounds.as_ref())?;
                    }
                }
                StructuredBlockContent::Table {
                    row_count,
                    column_count,
                    cells,
                    continuation_rows,
                    unassigned_lines,
                } => {
                    for line in cells
                        .iter()
                        .flat_map(|cell| &cell.lines)
                        .chain(unassigned_lines)
                    {
                        validate_bounds(line.bounds.as_ref())?;
                    }
                    validate_table(*row_count, *column_count, cells, continuation_rows)?;
                }
            }
        }
    }
    Ok(())
}

fn validate_table(
    row_count: u32,
    column_count: u32,
    cells: &[pdf_inspector::StructuredTableCell],
    continuation_rows: &[pdf_inspector::StructuredTableContinuation],
) -> Result<(), ErrorPayload> {
    let slot_count = row_count
        .checked_mul(column_count)
        .ok_or_else(|| structured_output_error("The structured table dimensions are too large"))?;
    if row_count == 0 || column_count == 0 || cells.len() > slot_count as usize {
        return Err(structured_output_error(
            "The structured table dimensions are invalid",
        ));
    }
    let mut seen_continuations = HashSet::new();
    if continuation_rows.iter().any(|entry| {
        entry.row >= row_count
            || entry.continuation_of >= entry.row
            || !seen_continuations.insert(entry.row)
    }) {
        return Err(structured_output_error(
            "The structured table contains invalid continuation rows",
        ));
    }

    let mut occupied = HashSet::new();
    let mut previous = None;
    for cell in cells {
        let position = (cell.row, cell.column);
        if previous.is_some_and(|previous| position <= previous)
            || cell.row_span == 0
            || cell.column_span == 0
        {
            return Err(structured_output_error(
                "The structured table cells are not in source order",
            ));
        }
        previous = Some(position);

        let row_end = cell.row.checked_add(cell.row_span).ok_or_else(|| {
            structured_output_error("A structured table cell has an invalid row span")
        })?;
        let column_end = cell.column.checked_add(cell.column_span).ok_or_else(|| {
            structured_output_error("A structured table cell has an invalid column span")
        })?;
        if cell.row >= row_count
            || cell.column >= column_count
            || row_end > row_count
            || column_end > column_count
        {
            return Err(structured_output_error(
                "A structured table cell falls outside its grid",
            ));
        }
        let inconsistent_evidence = match cell.state {
            StructuredCellState::Extracted => cell.lines.is_empty() || cell.detected_text.is_some(),
            StructuredCellState::Empty => !cell.lines.is_empty() || cell.detected_text.is_some(),
            StructuredCellState::Unresolved => false,
        };
        if inconsistent_evidence || cell.detected_text.as_deref().is_some_and(str::is_empty) {
            return Err(structured_output_error(
                "A structured table cell has inconsistent source evidence",
            ));
        }
        validate_bounds(cell.bounds.as_ref())?;
        for line in &cell.lines {
            validate_bounds(line.bounds.as_ref())?;
        }
        for row in cell.row..row_end {
            for column in cell.column..column_end {
                if !occupied.insert((row, column)) {
                    return Err(structured_output_error(
                        "The structured table contains overlapping cells",
                    ));
                }
            }
        }
    }
    if occupied.len() != slot_count as usize {
        return Err(structured_output_error(
            "The structured table does not cover its full grid",
        ));
    }
    Ok(())
}

fn validate_bounds(bounds: Option<&StructuredBounds>) -> Result<(), ErrorPayload> {
    let Some(bounds) = bounds else {
        return Ok(());
    };
    let right = bounds.x + bounds.width;
    let bottom = bounds.y + bounds.height;
    if !(bounds.x.is_finite()
        && bounds.y.is_finite()
        && bounds.width.is_finite()
        && bounds.height.is_finite()
        && bounds.x >= 0.0
        && bounds.y >= 0.0
        && bounds.width > 0.0
        && bounds.height > 0.0
        && bounds.x <= 1.0
        && bounds.y <= 1.0
        && bounds.width <= 1.0
        && bounds.height <= 1.0
        && right <= 1.0 + f32::EPSILON * 8.0
        && bottom <= 1.0 + f32::EPSILON * 8.0)
    {
        return Err(structured_output_error(
            "The structured document contains invalid normalized bounds",
        ));
    }
    Ok(())
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
        br#"{"schema_version":3,"ok":false,"result":null,"error":{"code":"serialization_error","message":"Could not encode the engine response"}}"#.to_vec()
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
    use pdf_inspector::{
        StructuredBlock, StructuredCellRole, StructuredPage, StructuredPageSize,
        StructuredTableCell, StructuredTextLine,
    };

    fn line(text: &str) -> StructuredTextLine {
        StructuredTextLine {
            text: text.to_owned(),
            bounds: None,
        }
    }

    fn valid_spanning_document() -> StructuredDocument {
        StructuredDocument {
            pages: vec![StructuredPage {
                page_index: 0,
                size: StructuredPageSize {
                    width: 612.0,
                    height: 792.0,
                },
                status: StructuredPageStatus::Extracted,
                blocks: vec![StructuredBlock {
                    id: "p0-b0".to_owned(),
                    bounds: None,
                    content: StructuredBlockContent::Table {
                        row_count: 2,
                        column_count: 2,
                        continuation_rows: Vec::new(),
                        cells: vec![
                            StructuredTableCell {
                                row: 0,
                                column: 0,
                                row_span: 2,
                                column_span: 1,
                                state: StructuredCellState::Extracted,
                                role: StructuredCellRole::Unknown,
                                lines: vec![line("Merged")],
                                detected_text: None,
                                bounds: None,
                            },
                            StructuredTableCell {
                                row: 0,
                                column: 1,
                                row_span: 1,
                                column_span: 1,
                                state: StructuredCellState::Extracted,
                                role: StructuredCellRole::Unknown,
                                lines: vec![line("Top")],
                                detected_text: None,
                                bounds: None,
                            },
                            StructuredTableCell {
                                row: 1,
                                column: 1,
                                row_span: 1,
                                column_span: 1,
                                state: StructuredCellState::Empty,
                                role: StructuredCellRole::Unknown,
                                lines: Vec::new(),
                                detected_text: None,
                                bounds: None,
                            },
                        ],
                        unassigned_lines: Vec::new(),
                    },
                }],
            }],
        }
    }

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

    #[test]
    fn null_structured_input_is_encoded_without_unwinding_across_the_abi() {
        let value = unsafe { documentkit_extract_document(std::ptr::null(), 0) };
        let json = std::str::from_utf8(unsafe { slice::from_raw_parts(value.data, value.length) })
            .unwrap();
        assert!(json.contains(r#""code":"invalid_input""#));
        unsafe { documentkit_buffer_free(value) };
    }

    #[test]
    fn validation_accepts_spanning_anchor_and_rejects_zero_area_bounds() {
        let document = valid_spanning_document();
        assert!(validate_structured_document(&document, None, 1, &[]).is_ok());

        let zero_area = StructuredBounds {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.2,
        };
        assert!(validate_bounds(Some(&zero_area)).is_err());
    }

    #[test]
    fn document_operation_omits_markdown_and_normalizes_layout_page_order() {
        let payload = result_payload(
            PdfProcessResult {
                pdf_type: PdfType::TextBased,
                markdown: Some("presentation markdown".to_owned()),
                page_count: 1,
                processing_time_ms: 0,
                pages_needing_ocr: Vec::new(),
                ocr_reasons_by_page: Vec::new(),
                title: None,
                author: None,
                subject: None,
                keywords: None,
                creator: None,
                producer: None,
                creation_date: None,
                mod_date: None,
                confidence: 1.0,
                layout: pdf_inspector::LayoutComplexity {
                    is_complex: true,
                    pages_with_tables: vec![1, 1],
                    pages_with_columns: vec![1, 1],
                },
                has_encoding_issues: false,
                cmap_gaps: Vec::new(),
                structured_document: Some(valid_spanning_document()),
            },
            None,
            Operation::ExtractDocument,
        )
        .unwrap_or_else(|_| panic!("valid structured result"));

        assert!(payload.markdown.is_none());
        assert_eq!(payload.pages_with_tables, vec![0]);
        assert_eq!(payload.pages_with_columns, vec![0]);
        assert!(payload.document.is_some());
    }
}
