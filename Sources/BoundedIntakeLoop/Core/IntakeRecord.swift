import Foundation

/// A single priced line on a receipt or shelf tag.
///
/// Money is carried as minor units (`Int` cents) rather than `Double`. A model
/// that has just read "12.99" off a photo will happily hand back `12.989999`,
/// and once that is added to twenty siblings the reconciliation tolerance has to
/// be widened until it stops catching real errors. Integers move the rounding
/// decision to one explicit place — ``Money/minorUnits(from:)`` — instead of
/// spreading it across every comparison.
public struct LineItem: Sendable, Equatable, Codable {
    public let label: String
    public let quantity: Int
    public let unitPriceMinorUnits: Int

    public init(label: String, quantity: Int, unitPriceMinorUnits: Int) {
        self.label = label
        self.quantity = quantity
        self.unitPriceMinorUnits = unitPriceMinorUnits
    }

    /// Extended price, saturating rather than trapping on a model-supplied
    /// quantity of `Int.max`.
    public var extendedMinorUnits: Int {
        Saturating.multiply(quantity, unitPriceMinorUnits)
    }
}

/// The structured record the pipeline exists to produce.
///
/// Every field is optional except `currencyCode` because the honest output of a
/// blurry photo is a partial record, and a pipeline that invents a merchant name
/// to fill a non-optional field is worse than one that admits it does not know.
public struct IntakeRecord: Sendable, Equatable, Codable {
    public let barcode: String?
    public let merchant: String?
    public let lineItems: [LineItem]
    /// The total as *printed on the document*, not as computed from line items.
    /// Keeping the two separate is what makes reconciliation possible at all.
    public let declaredTotalMinorUnits: Int?
    public let currencyCode: String

    public init(
        barcode: String? = nil,
        merchant: String? = nil,
        lineItems: [LineItem] = [],
        declaredTotalMinorUnits: Int? = nil,
        currencyCode: String
    ) {
        self.barcode = barcode
        self.merchant = merchant
        self.lineItems = lineItems
        self.declaredTotalMinorUnits = declaredTotalMinorUnits
        self.currencyCode = currencyCode
    }

    /// Sum of extended line prices, saturating.
    public var computedTotalMinorUnits: Int {
        lineItems.reduce(0) { Saturating.add($0, $1.extendedMinorUnits) }
    }
}

/// Helpers for turning the decimal strings a model emits into minor units.
public enum Money {
    /// Converts a decimal amount to minor units, rejecting values that cannot be
    /// represented meaningfully rather than clamping them into plausibility.
    ///
    /// Uses `rounded()` on the scaled value before conversion, so `12.989999`
    /// becomes `1299` rather than `1298` — truncation toward zero is the wrong
    /// default for money read off a photo.
    public static func minorUnits(from amount: Double, scale: Int = 100) -> Int? {
        guard Saturating.isUsableAmount(amount), scale > 0 else { return nil }
        let scaled = (amount * Double(scale)).rounded()
        return Saturating.int(scaled)
    }

    /// Renders minor units for display without going through `Double`.
    ///
    /// `NumberFormatter` would take an `NSNumber` built from a `Double` and
    /// reintroduce exactly the representation error the integer pipeline exists
    /// to avoid, one line before the number reaches the user's eyes.
    public static func string(minorUnits: Int, scaleDigits: Int = 2) -> String {
        guard scaleDigits > 0 else { return String(minorUnits) }
        // `Int.min` has no positive magnitude, so `magnitude` (a `UInt`) is used
        // rather than `abs`, which traps on exactly that value.
        let magnitude = minorUnits.magnitude
        var divisor: UInt = 1
        for _ in 0..<scaleDigits {
            let (next, overflow) = divisor.multipliedReportingOverflow(by: 10)
            if overflow { break }
            divisor = next
        }
        let whole = magnitude / divisor
        let fraction = magnitude % divisor
        var fractionText = String(fraction)
        while fractionText.count < scaleDigits {
            fractionText = "0" + fractionText
        }
        let sign = minorUnits < 0 ? "-" : ""
        return "\(sign)\(whole).\(fractionText)"
    }
}

/// Every way a draft record can fail its invariants.
///
/// These are values, not thrown errors, because the loop routes on them: a
/// checksum failure means "retry with the barcode tool", while a currency
/// failure means "the model is confused, fall back".
public enum ValidationFailure: Sendable, Equatable, Codable {
    case malformedCurrencyCode(String)
    case barcodeCheckDigitMismatch(barcode: String, expected: Int, found: Int)
    case barcodeUnsupportedLength(barcode: String, length: Int)
    case barcodeNonNumeric(barcode: String)
    case nonPositiveQuantity(label: String, quantity: Int)
    case negativeUnitPrice(label: String, minorUnits: Int)
    case totalMismatch(declared: Int, computed: Int, toleranceMinorUnits: Int)
    case tooManyLineItems(count: Int, limit: Int)
    case emptyRecord
}
