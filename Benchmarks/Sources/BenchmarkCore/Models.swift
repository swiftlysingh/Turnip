import Foundation

/// Benchmark-only identifiers. This target is intentionally not a package product.
enum BenchmarkProfile {
    static let identifier = "amex-retrobudget-v1"
    static let schemaVersion = 2
    static let adapterRevision = "amex-adapter-v1"
}

enum StatementVariant: String, Codable, CaseIterable, Sendable {
    case standard
    case screenReader = "screen-reader"
}

enum CriticalValueKind: String, Codable, Sendable {
    case amount
    case date
}

struct TransactionRow: Codable, Hashable, Sendable {
    let date: String
    let merchant: String
    let signedAmountMinor: Int64

    /// Zero-based source provenance. It is deliberately excluded from row matching.
    let pageIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case date
        case merchant
        case signedAmountMinor = "signed_amount_minor"
        case pageIndex = "page_index"
    }
}

struct CanonicalCriticalValue: Codable, Hashable, Sendable {
    let id: String
    let kind: CriticalValueKind
    let signedAmountMinor: Int64?
    let date: String?
    let currency: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case signedAmountMinor = "signed_amount_minor"
        case date
        case currency
    }
}

struct FinancialExtraction: Codable, Hashable, Sendable {
    let statementCurrency: String?
    let statementPeriod: String?
    let transactions: [TransactionRow]
    let criticalValues: [CanonicalCriticalValue]
    let malformedTransactionCandidates: Int
    let unexpectedCriticalCandidates: Int

    init(
        statementCurrency: String?,
        statementPeriod: String? = nil,
        transactions: [TransactionRow],
        criticalValues: [CanonicalCriticalValue],
        malformedTransactionCandidates: Int = 0,
        unexpectedCriticalCandidates: Int = 0
    ) {
        self.statementCurrency = statementCurrency
        self.statementPeriod = statementPeriod
        self.transactions = transactions
        self.criticalValues = criticalValues
        self.malformedTransactionCandidates = malformedTransactionCandidates
        self.unexpectedCriticalCandidates = unexpectedCriticalCandidates
    }
}

/// A tracked, checksum-pinned canonical Markdown projection. The renderer is
/// deterministic, so every reviewed field association is checked directly
/// against structured truth before benchmark execution.
struct CanonicalMarkdownReference: Codable, Hashable, Sendable {
    let path: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
    }
}

struct FinancialTruth: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let statementID: String
    let statementPeriod: String
    let statementCurrency: String
    let transactions: [TransactionRow]
    let criticalValues: [CanonicalCriticalValue]
    let canonicalMarkdown: CanonicalMarkdownReference

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case statementID = "statement_id"
        case statementPeriod = "statement_period"
        case statementCurrency = "statement_currency"
        case transactions
        case criticalValues = "critical_values"
        case canonicalMarkdown = "canonical_markdown"
    }
}

enum ReviewStatus: String, Codable, Sendable {
    case pending = "review_pending"
    case complete
}

enum ReviewActorKind: String, Codable, Sendable {
    case human
    case model
}

struct ReviewPrompt: Codable, Hashable, Sendable {
    let text: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case text
        case sha256
    }
}

/// A completed participant is bound to an exact source-only prompt stored in
/// the review record. The review record itself is checksum-pinned by manifest.
struct ReviewParticipant: Codable, Hashable, Sendable {
    let kind: ReviewActorKind
    let model: String?
    let reasoningEffort: String?
    let prompt: ReviewPrompt

    private enum CodingKeys: String, CodingKey {
        case kind
        case model
        case reasoningEffort = "reasoning_effort"
        case prompt
    }
}

/// Historical authorship can be retained even where the exact prompt was not
/// preserved. It never substitutes for the independently reproducible author
/// reconstruction required to complete a review record.
struct PriorAuthorRecord: Codable, Hashable, Sendable {
    let kind: ReviewActorKind
    let model: String?
    let reasoningEffort: String?
    /// Historical prompt bytes are unavailable. This record is provenance only,
    /// never a substitute for the pinned reconstruction prompt below.
    let exactPromptNotRetained: Bool

    private enum CodingKeys: String, CodingKey {
        case kind
        case model
        case reasoningEffort = "reasoning_effort"
        case exactPromptNotRetained = "exact_prompt_not_retained"
    }
}

struct ReviewSourceVariant: Codable, Hashable, Sendable {
    let variant: StatementVariant
    let pdfSHA256: String
    let pdfPageCount: Int

    private enum CodingKeys: String, CodingKey {
        case variant
        case pdfSHA256 = "pdf_sha256"
        case pdfPageCount = "pdf_page_count"
    }
}

/// A checksum-pinned adjudication resolves the independent reconstructions
/// against rendered pages, locked conventions, and the final truth projection.
/// It never consults candidate output.
struct ReviewAdjudicationResult: Codable, Hashable, Sendable {
    let unresolvedTransactionDiscrepancies: Int
    let unresolvedCriticalDiscrepancies: Int

    private enum CodingKeys: String, CodingKey {
        case unresolvedTransactionDiscrepancies = "unresolved_transaction_discrepancies"
        case unresolvedCriticalDiscrepancies = "unresolved_critical_discrepancies"
    }
}

struct ReviewAdjudication: Codable, Hashable, Sendable {
    let adjudicator: ReviewParticipant
    let adjudicationResult: ReviewAdjudicationResult

    private enum CodingKeys: String, CodingKey {
        case adjudicator
        case adjudicationResult = "adjudication_result"
    }
}

/// One checksum-pinned review record is mandatory for every locked truth group,
/// including a group with only one source variant.
struct TruthReviewRecord: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let reviewStatus: ReviewStatus
    let statementID: String
    let statementPeriod: String
    let statementCurrency: String
    let truthSHA256: String
    let canonicalMarkdownSHA256: String
    let sources: [ReviewSourceVariant]
    let priorAuthor: PriorAuthorRecord?
    let authorReconstructionPrompt: ReviewPrompt
    let reviewerReconstructionPrompt: ReviewPrompt
    let author: ReviewParticipant?
    let reviewer: ReviewParticipant?
    let authorReviewerIndependent: Bool
    let sourceOnlyAuthoring: Bool
    let sourceOnlyReview: Bool
    let allPagesVisuallyInspected: Bool
    let candidateOutputsConsulted: Bool
    let unresolvedTransactionDiscrepancies: Bool
    let unresolvedCriticalDiscrepancies: Bool
    let semanticEquivalence: Bool?
    let adjudication: ReviewAdjudication?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reviewStatus = "review_status"
        case statementID = "statement_id"
        case statementPeriod = "statement_period"
        case statementCurrency = "statement_currency"
        case truthSHA256 = "truth_sha256"
        case canonicalMarkdownSHA256 = "canonical_markdown_sha256"
        case sources
        case priorAuthor = "prior_author"
        case authorReconstructionPrompt = "author_reconstruction_prompt"
        case reviewerReconstructionPrompt = "reviewer_reconstruction_prompt"
        case author
        case reviewer
        case authorReviewerIndependent = "author_reviewer_independent"
        case sourceOnlyAuthoring = "source_only_authoring"
        case sourceOnlyReview = "source_only_review"
        case allPagesVisuallyInspected = "all_pages_visually_inspected"
        case candidateOutputsConsulted = "candidate_outputs_consulted"
        case unresolvedTransactionDiscrepancies = "unresolved_transaction_discrepancies"
        case unresolvedCriticalDiscrepancies = "unresolved_critical_discrepancies"
        case semanticEquivalence = "semantic_equivalence"
        case adjudication
    }
}

struct TruthReviewReference: Codable, Hashable, Sendable {
    let path: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
    }
}

struct BenchmarkCase: Codable, Hashable, Sendable {
    let caseToken: String
    let statementID: String
    let statementPeriod: String
    let variant: StatementVariant
    let pdf: String
    let truth: String
    let pdfSHA256: String
    let pdfByteCount: Int
    let pdfPageCount: Int
    let truthSHA256: String
    let review: TruthReviewReference

    private enum CodingKeys: String, CodingKey {
        case caseToken = "case_token"
        case statementID = "statement_id"
        case statementPeriod = "statement_period"
        case variant
        case pdf
        case truth
        case pdfSHA256 = "pdf_sha256"
        case pdfByteCount = "pdf_byte_count"
        case pdfPageCount = "pdf_page_count"
        case truthSHA256 = "truth_sha256"
        case review
    }
}

struct BenchmarkManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let profile: String
    let turnipRevision: String
    let adapterRevision: String
    let adapterChecksum: String
    let cases: [BenchmarkCase]

    // The schema-v2 key stays stable so existing private manifests still load.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profile
        case turnipRevision = "documentkit_revision"
        case adapterRevision = "adapter_revision"
        case adapterChecksum = "adapter_checksum"
        case cases
    }
}

public enum BenchmarkFailure: Error, Sendable, Equatable {
    case invalidInvocation
    case invalidManifest
    case invalidTruth
    case invalidEquivalenceReview
    case inputValidationFailed
    case reportWritingFailed
    case privacyGuardFailed
    case internalRunnerFailure

    public var code: String {
        switch self {
        case .invalidInvocation: "invalid_invocation"
        case .invalidManifest: "invalid_manifest"
        case .invalidTruth: "invalid_truth"
        case .invalidEquivalenceReview: "invalid_equivalence_review"
        case .inputValidationFailed: "input_validation_failed"
        case .reportWritingFailed: "report_writing_failed"
        case .privacyGuardFailed: "privacy_guard_failed"
        case .internalRunnerFailure: "internal_runner_failure"
        }
    }
}

enum AdapterFailure: Error, Sendable, Equatable {
    case emptySurface
    case missingTransactionSection
    case conflictingStatementMetadata

    var code: String {
        switch self {
        case .emptySurface: "adapter_empty_surface"
        case .missingTransactionSection: "adapter_missing_transaction_section"
        case .conflictingStatementMetadata: "adapter_conflicting_statement_metadata"
        }
    }
}

enum CandidateOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case success(Value)
    case failure(String)
}

struct MultisetScore: Equatable, Sendable {
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let f1: Double
}

struct FinancialScore: Equatable, Sendable {
    let row: MultisetScore
    let cell: MultisetScore
    let contentTokenF1: Double
    let criticalAccuracy: Double
    let correctCriticalValues: Int
    let expectedCriticalValues: Int
    let unexpectedCriticalValues: Int
    let duplicateCriticalValues: Int
    let malformedTransactionCandidates: Int
    let perfect: Bool

    static func failed(expectedRows: Int, expectedCriticalValues: Int) -> FinancialScore {
        FinancialScore(
            row: MultisetScore(
                truePositive: 0,
                falsePositive: 0,
                falseNegative: expectedRows,
                f1: 0
            ),
            cell: MultisetScore(
                truePositive: 0,
                falsePositive: 0,
                falseNegative: expectedRows * 3,
                f1: 0
            ),
            contentTokenF1: 0,
            criticalAccuracy: 0,
            correctCriticalValues: 0,
            expectedCriticalValues: expectedCriticalValues,
            unexpectedCriticalValues: 0,
            duplicateCriticalValues: 0,
            malformedTransactionCandidates: 0,
            perfect: false
        )
    }
}
