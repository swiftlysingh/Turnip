import Foundation

enum CanonicalMarkdown {
    static let formatRevision = "AMEX benchmark canonical source v1"

    static func render(_ truth: FinancialTruth) -> String {
        var lines = [
            "# \(formatRevision)",
            "",
            "statement_currency: \(truth.statementCurrency)",
            "statement_period: \(truth.statementPeriod)",
            "",
            "## Transactions",
            "",
            "| date | merchant | signed_amount_minor | page_index |",
            "| --- | --- | ---: | ---: |",
        ]
        for row in truth.transactions {
            lines.append(
                "| \(row.date) | \(cell(row.merchant)) | \(row.signedAmountMinor) | \(row.pageIndex.map(String.init) ?? "") |"
            )
        }
        lines += [
            "",
            "## Critical Values",
            "",
            "| id | kind | signed_amount_minor | date | currency |",
            "| --- | --- | ---: | --- | --- |",
        ]
        for value in truth.criticalValues {
            lines.append(
                "| \(cell(value.id)) | \(value.kind.rawValue) | \(value.signedAmountMinor.map(String.init) ?? "") | \(value.date ?? "") | \(value.currency ?? "") |"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func isRepresentable(_ truth: FinancialTruth) -> Bool {
        truth.transactions.allSatisfy { !containsLineBreak($0.merchant) }
            && truth.criticalValues.allSatisfy {
                !containsLineBreak($0.id)
                    && !containsLineBreak($0.date ?? "")
                    && !containsLineBreak($0.currency ?? "")
            }
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func containsLineBreak(_ value: String) -> Bool {
        value.contains(where: { $0.isNewline })
    }
}
