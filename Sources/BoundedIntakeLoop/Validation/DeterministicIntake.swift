import Foundation

/// Builds a record from grounding evidence alone.
///
/// This is the path taken whenever the model loop ends without a validated
/// record — unavailable model, exhausted budget, contract violation, or a draft
/// that kept failing its invariants. It is not a degraded mode bolted on at the
/// end; it is the reason the loop is allowed to be bounded in the first place.
/// A loop that must keep retrying until the model succeeds has no bound, because
/// its stopping condition belongs to the model.
public struct DeterministicIntake: Sendable {
    public let parser: ReceiptTextParser
    public let currencyCode: String
    /// Ceiling on how many recognized-text lines are accumulated across *all*
    /// evidence before parsing.
    ///
    /// `ReceiptTextParser.maximumLines` bounds the scan; this bounds the
    /// accumulation, which is a different thing — without it, four tool results
    /// of a million lines each become four million strings in one array before
    /// the parser's cap is ever consulted. Honest limit: a single tool payload
    /// is already materialised as `[String]` by the time it reaches this
    /// module, so this caps what the *pipeline* holds, not what a pathological
    /// tool allocates on its own.
    public let maximumEvidenceLines: Int

    public init(
        parser: ReceiptTextParser = ReceiptTextParser(),
        currencyCode: String,
        maximumEvidenceLines: Int = 512
    ) {
        self.parser = parser
        self.currencyCode = currencyCode
        self.maximumEvidenceLines = max(1, maximumEvidenceLines)
    }

    /// Returns `nil` when the evidence contains nothing usable — an honest
    /// "I could not read this" rather than an empty record that will be
    /// mistaken for a successful read downstream.
    public func record(from evidence: [ToolResult]) -> IntakeRecord? {
        var textLines: [String] = []
        var barcode: String?
        var merchant: String?
        var keyValueTotal: Int?

        for result in evidence {
            switch result.payload {
            case .recognizedText(let lines):
                let room = maximumEvidenceLines - textLines.count
                if room > 0 {
                    textLines.append(contentsOf: lines.prefix(room))
                }
            case .barcode(let value):
                // Only a barcode that passes its own check digit is accepted.
                // The fallback holding itself to the same arithmetic it holds
                // the model to is the point: otherwise "deterministic" just
                // means "wrong in a repeatable way".
                if barcode == nil, GTIN.validate(value) == nil {
                    barcode = value
                }
            case .keyValues(let pairs):
                if merchant == nil, let value = pairs["merchant"], !value.isEmpty {
                    merchant = value
                }
                if keyValueTotal == nil, let value = pairs["total"] {
                    keyValueTotal = ReceiptTextParser.minorUnits(fromToken: value)
                }
            case .unavailable:
                continue
            }
        }

        let parsed = parser.parse(textLines)
        let record = IntakeRecord(
            barcode: barcode,
            merchant: merchant ?? parsed.merchant,
            lineItems: parsed.lineItems,
            declaredTotalMinorUnits: parsed.declaredTotalMinorUnits ?? keyValueTotal,
            currencyCode: currencyCode
        )

        let isEmpty = record.barcode == nil
            && record.lineItems.isEmpty
            && record.declaredTotalMinorUnits == nil
            && (record.merchant?.isEmpty ?? true)
        return isEmpty ? nil : record
    }
}
