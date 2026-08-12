#!/usr/bin/env swift

import Foundation

// This generator exists only to make the committed benchmark fixture
// reproducible. PDF generation is not part of the DocumentKit SDK.
let content = """
BT
/F1 26 Tf
72 720 Td
(DocumentKit Fixture) Tj
/F1 12 Tf
0 -40 Td
(A small document checks native Swift extraction.) Tj
/F1 16 Tf
0 -36 Td
(Benchmark objectives) Tj
/F1 12 Tf
0 -26 Td
(- Preserve page order) Tj
0 -22 Td
(- Recover readable text) Tj
0 -22 Td
(- Produce deterministic Markdown) Tj
0 -34 Td
(Edition: 2026) Tj
ET
"""

let objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
    "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    "<< /Title (DocumentKit Fixture) /Author (DocumentKit contributors) /Creator (generate-fixture.swift) >>",
]

var pdf = Data("%PDF-1.4\n".utf8)
var offsets = [0]
for (index, object) in objects.enumerated() {
    offsets.append(pdf.count)
    pdf.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
}

let xrefOffset = pdf.count
pdf.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
pdf.append(Data("0000000000 65535 f \n".utf8))
for offset in offsets.dropFirst() {
    pdf.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
}
pdf.append(
    Data(
        "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 6 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8
    )
)

let outputURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("documentkit-fixture.pdf")
try pdf.write(to: outputURL, options: .atomic)
print("Wrote \(pdf.count) bytes to \(outputURL.path)")
