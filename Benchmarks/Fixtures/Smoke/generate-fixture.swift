#!/usr/bin/env swift

import Foundation

// This is invented fixture content. The small PDF serializer deliberately uses
// only fixed PDF syntax and built-in Helvetica, avoiding CoreGraphics metadata
// such as host-specific producer strings so byte-for-byte regeneration works on
// every supported macOS CI image. It is not a statement, a template, or a
// transcription of real data.
let standardLines = [
    "AMEX SYNTHETIC STATEMENT",
    "Statement Period: 01/01/2026 - 01/31/2026",
    "Currency: USD",
    "New Balance: $127.33",
    "Minimum Payment: $25.00",
    "Payment Due Date: 02/15/2026",
    "Credit Limit: $1,000.00",
    "Payments/Credits: $50.00 CR",
    "Fees: $0.00",
    "Interest: $1.23",
    "Transactions",
    "Date Description Amount",
    "01/03 Lantern Cafe $12.34",
    "01/04 Orbit Paper Co. ($5.00)",
    "01/04 Orbit Paper Co. ($5.00)",
    "01/06 Northwind Books $9.99-",
]

// This is an invented screen-reader-shaped representation, not a claimed export
// from an accessibility tool. It keeps the same financial meaning while moving
// summaries after the table and wrapping one merchant across adjacent lines.
let screenReaderLines = [
    "AMEX SYNTHETIC STATEMENT",
    "Statement Period: 01/01/2026 - 01/31/2026",
    "Currency: USD",
    "Transactions",
    "Date Description Amount",
    "01/03 Lantern Cafe $12.34",
    "01/04 Orbit Paper Co. ($5.00)",
    "01/04 Orbit Paper Co. ($5.00)",
    "01/06 Northwind",
    "Books $9.99-",
    "Transaction Summary",
    "New Balance: $127.33",
    "Minimum Payment: $25.00",
    "Payment Due Date: 02/15/2026",
    "Credit Limit: $1,000.00",
    "Payments/Credits: $50.00 CR",
    "Fees: $0.00",
    "Interest: $1.23",
]

func outputDirectory() throws -> URL {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2, arguments[0] == "--output-dir" else {
        throw FixtureError.invalidInvocation
    }
    let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func makePDF(lines: [String], lineSpacing: Double, identifier: String) throws -> Data {
    guard identifier.count == 32, identifier.allSatisfy(\.isHexDigit) else {
        throw FixtureError.pdfCreationFailed
    }
    let leading = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), lineSpacing)
    var stream = "BT\n/F1 11 Tf\n72 740 Td\n"
    for (index, line) in lines.enumerated() {
        stream += "(\(try escapePDFText(line))) Tj\n"
        if index + 1 < lines.count { stream += "0 -\(leading) Td\n" }
    }
    stream += "ET\n"
    let streamData = Data(stream.utf8)
    let objects = [
        "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
        "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    ]
    var data = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
    var offsets = [0]
    for object in objects {
        offsets.append(data.count)
        data.append(Data(object.utf8))
    }
    offsets.append(data.count)
    data.append(Data("5 0 obj\n<< /Length \(streamData.count) >>\nstream\n".utf8))
    data.append(streamData)
    data.append(Data("endstream\nendobj\n".utf8))

    let xrefOffset = data.count
    data.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() {
        data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    data.append(Data("trailer\n<< /Size 6 /Root 1 0 R /ID [<\(identifier)> <\(identifier)>] >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
    return data
}

func escapePDFText(_ value: String) throws -> String {
    guard value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
        throw FixtureError.pdfCreationFailed
    }
    return value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
}

enum FixtureError: Error {
    case invalidInvocation
    case pdfCreationFailed
}

let directory = try outputDirectory()
try makePDF(
    lines: standardLines,
    lineSpacing: 18,
    identifier: "11111111111111111111111111111111"
).write(to: directory.appendingPathComponent("synthetic-amex-standard.pdf"), options: .atomic)
try makePDF(
    lines: screenReaderLines,
    lineSpacing: 18.25,
    identifier: "22222222222222222222222222222222"
).write(to: directory.appendingPathComponent("synthetic-amex-screen-reader.pdf"), options: .atomic)
