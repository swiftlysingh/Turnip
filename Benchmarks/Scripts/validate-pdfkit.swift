import Foundation
import PDFKit

func fail(_ message: String) -> Never {
    fputs("PDF validation failed: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 3,
      let expectedPages = Int(CommandLine.arguments[2]),
      expectedPages > 0 else {
    fputs("usage: validate-pdfkit <pdf> <expected-pages>\n", stderr)
    exit(64)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      data.starts(with: Data("%PDF-".utf8)) else {
    fail("missing PDF header: \(url.path)")
}
guard let document = PDFDocument(data: data) else {
    fail("PDFKit could not open: \(url.path)")
}
guard !document.isLocked else {
    fail("document is locked: \(url.path)")
}
guard document.pageCount == expectedPages else {
    fail("expected \(expectedPages) pages, found \(document.pageCount): \(url.path)")
}
for index in 0..<document.pageCount where document.page(at: index) == nil {
    fail("page \(index + 1) is unreadable: \(url.path)")
}

print("PDFKit OK\t\(url.lastPathComponent)\t\(document.pageCount) pages")
