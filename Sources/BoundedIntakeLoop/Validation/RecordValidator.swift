import Foundation

/// Domain invariants a draft record must satisfy before anything downstream is
/// allowed to treat it as fact.
///
/// The policy is deliberately separate from the loop. The loop decides *how many
/// times* to ask; this decides *whether the answer is acceptable*. Keeping them
/// apart is what lets the same invariants run over the deterministic fallback
/// path, which never talked to a model at all.
public struct ValidationPolicy: Sendable, Equatable {
    /// How far the printed total may differ from the summed line items before the
    /// record is rejected. Non-zero by default because real receipts carry taxes,
    /// deposits and rounding lines that a line-item extractor will not see.
    public let totalToleranceMinorUnits: Int
    /// Hard cap on line items. A model in a degenerate repetition loop will emit
    /// the same line thousands of times; without a cap that becomes an unbounded
    /// allocation driven by model output.
    public let maximumLineItems: Int
    /// When true, a record with no barcode, no merchant and no line items is
    /// rejected rather than returned as a technically-valid empty shell.
    public let rejectsEmptyRecords: Bool

    public init(
        totalToleranceMinorUnits: Int = 0,
        maximumLineItems: Int = 256,
        rejectsEmptyRecords: Bool = true
    ) {
        self.totalToleranceMinorUnits = max(0, totalToleranceMinorUnits)
        self.maximumLineItems = max(1, maximumLineItems)
        self.rejectsEmptyRecords = rejectsEmptyRecords
    }

    public static let strict = ValidationPolicy()
    /// Tolerates up to one currency unit of drift, for documents where tax lines
    /// are printed but not itemised.
    public static let receiptFriendly = ValidationPolicy(totalToleranceMinorUnits: 100)
}

public struct RecordValidator: Sendable {
    public let policy: ValidationPolicy

    public init(policy: ValidationPolicy = .strict) {
        self.policy = policy
    }

    /// Returns every failure found, not just the first.
    ///
    /// The loop routes on the *set* of failures: a lone checksum mismatch is
    /// worth one more grounding call, while a checksum mismatch plus a total
    /// mismatch plus a bad currency code means the model has lost the plot and
    /// the fallback should take over immediately.
    public func validate(_ record: IntakeRecord) -> [ValidationFailure] {
        var failures: [ValidationFailure] = []

        if !isWellFormedCurrencyCode(record.currencyCode) {
            failures.append(.malformedCurrencyCode(record.currencyCode))
        }

        if record.lineItems.count > policy.maximumLineItems {
            failures.append(.tooManyLineItems(
                count: record.lineItems.count,
                limit: policy.maximumLineItems
            ))
        }

        if let barcode = record.barcode, let failure = GTIN.validate(barcode) {
            failures.append(failure)
        }

        // Only the items within the cap are inspected: past the cap the record is
        // already rejected, and walking a million model-authored lines to produce
        // a million failures is the same unbounded-work problem one layer down.
        for item in record.lineItems.prefix(policy.maximumLineItems) {
            if item.quantity <= 0 {
                failures.append(.nonPositiveQuantity(label: item.label, quantity: item.quantity))
            }
            if item.unitPriceMinorUnits < 0 {
                failures.append(.negativeUnitPrice(label: item.label, minorUnits: item.unitPriceMinorUnits))
            }
        }

        if let declared = record.declaredTotalMinorUnits, !record.lineItems.isEmpty {
            let computed = record.computedTotalMinorUnits
            // `Saturating.distance`, not `abs(_:)`: `declared` comes straight
            // off the model, and `abs(Int.min)` traps.
            let drift = Saturating.distance(declared, computed)
            if drift > policy.totalToleranceMinorUnits {
                failures.append(.totalMismatch(
                    declared: declared,
                    computed: computed,
                    toleranceMinorUnits: policy.totalToleranceMinorUnits
                ))
            }
        }

        if policy.rejectsEmptyRecords && isEmpty(record) {
            failures.append(.emptyRecord)
        }

        return failures
    }

    private func isEmpty(_ record: IntakeRecord) -> Bool {
        record.barcode == nil
            && record.lineItems.isEmpty
            && (record.merchant?.isEmpty ?? true)
            && record.declaredTotalMinorUnits == nil
    }

    /// ISO 4217 alpha-3: exactly three ASCII uppercase letters.
    private func isWellFormedCurrencyCode(_ code: String) -> Bool {
        guard code.count == 3 else { return false }
        return code.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }
}
