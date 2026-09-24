import Foundation

/// Where a record came from. Carried with the record, not inferred later,
/// because "the model read this" and "OCR read this" carry different confidence
/// and any downstream surface that treats them identically is lying to the user.
public enum Provenance: String, Sendable, Equatable, Codable {
    case model
    case deterministicFallback
    case none
}

/// Everything one run produced, including the runs that produced nothing.
public struct IntakeResult: Sendable, Equatable {
    /// `nil` when neither the model nor the fallback could read anything.
    public let record: IntakeRecord?
    public let provenance: Provenance
    /// Why the model loop stopped. Present even on success.
    public let termination: TerminationCause
    /// Validation failures still outstanding on the returned record. Non-empty
    /// only when the fallback also failed validation, in which case the record
    /// is returned anyway *with its failures attached* — the caller can show a
    /// partial read for correction, which is more useful than a blank screen,
    /// as long as it is never mistaken for a clean one.
    public let outstandingFailures: [ValidationFailure]
    public let budget: BudgetSnapshot
    public let trace: [TraceEvent]

    public var isTrustworthy: Bool {
        record != nil && outstandingFailures.isEmpty
    }
}
