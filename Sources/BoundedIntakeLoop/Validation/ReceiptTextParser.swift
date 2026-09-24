import Foundation

/// Turns recognized text lines into line items and a declared total — with no
/// model involved.
///
/// This exists so the pipeline has a floor. Every discussion of on-device
/// inference eventually reaches "what happens when the model is unavailable",
/// and the usual answer — show an error — is the wrong one for an intake screen,
/// because the OCR that grounded the model is still right there and still
/// readable. The parser is deliberately dumb and deliberately deterministic: it
/// never guesses, it skips what it does not understand, and the same
/// ``RecordValidator`` that judges the model's output judges this too.
///
/// Parsing is integer-only. `"12.99"` becomes `1299` without ever becoming
/// `12.99` as a `Double`, so no rounding error is introduced before the
/// reconciliation that is supposed to detect rounding errors.
public struct ReceiptTextParser: Sendable {

    /// Labels that are printed like line items but are not line items.
    /// `SUBTOTAL` is skipped because counting it double-counts every item above
    /// it; `TAX` is *kept* because it is a genuine priced line and keeping it is
    /// what lets the sum reconcile exactly against the printed total.
    private static let skippedLabels: Set<String> = [
        "SUBTOTAL", "CHANGE", "CASH", "CARD", "BALANCE", "TENDER", "CHANGEDUE"
    ]
    private static let totalLabels: Set<String> = [
        "TOTAL", "GRANDTOTAL", "AMOUNTDUE", "TOTALDUE"
    ]
    private static let currencySymbols: Set<Character> = ["$", "£", "€", "¥", "₹"]

    /// Upper bound on lines examined. OCR output length is driven by the photo,
    /// which is driven by the user, which is not a bound at all.
    public let maximumLines: Int

    public init(maximumLines: Int = 512) {
        self.maximumLines = max(1, maximumLines)
    }

    public struct Parsed: Sendable, Equatable {
        public var lineItems: [LineItem] = []
        public var declaredTotalMinorUnits: Int?
        public var merchant: String?
    }

    public func parse(_ lines: [String]) -> Parsed {
        var parsed = Parsed()
        // `prefix` is safe on any count, including zero.
        for (index, rawLine) in lines.prefix(maximumLines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            guard let split = splitTrailingAmount(line) else {
                // A line with no amount is a candidate merchant name, but only
                // the first one — a footer address line is not a merchant.
                if index == 0, parsed.merchant == nil, line.count <= 64 {
                    parsed.merchant = line
                }
                continue
            }

            let normalized = normalizeLabel(split.label)
            if Self.totalLabels.contains(normalized) {
                // Last total wins: receipts that reprint the total in a footer
                // are printing the same number, and a later line is more likely
                // to be the final one after discounts.
                parsed.declaredTotalMinorUnits = split.minorUnits
                continue
            }
            if Self.skippedLabels.contains(normalized) { continue }
            guard !normalized.isEmpty else { continue }

            let quantity = extractQuantity(from: split.label)
            // The printed amount on a receipt line is the *extended* price. The
            // unit price is derived, and a quantity that does not divide evenly
            // is reported as quantity 1 at the extended price rather than
            // silently rounded — a rounded unit price would fail reconciliation
            // against the very total it came from.
            if quantity.count > 1,
               let unit = Saturating.divide(split.minorUnits, quantity.count),
               Saturating.multiply(unit, quantity.count) == split.minorUnits {
                parsed.lineItems.append(LineItem(
                    label: quantity.label,
                    quantity: quantity.count,
                    unitPriceMinorUnits: unit
                ))
            } else {
                parsed.lineItems.append(LineItem(
                    label: quantity.label,
                    quantity: 1,
                    unitPriceMinorUnits: split.minorUnits
                ))
            }
        }
        return parsed
    }

    // MARK: - Lexing

    struct AmountSplit: Equatable {
        let label: String
        let minorUnits: Int
    }

    /// Splits a line into "everything before the trailing amount" and the amount.
    func splitTrailingAmount(_ line: String) -> AmountSplit? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let last = tokens.last,
              let minorUnits = Self.minorUnits(fromToken: String(last)) else {
            return nil
        }
        let label = tokens.dropLast().joined(separator: " ")
        return AmountSplit(label: label, minorUnits: minorUnits)
    }

    /// Integer-only decimal parsing. Returns `nil` for anything that is not
    /// unambiguously an amount, which is the behaviour that keeps a stray
    /// `"2026"` in a date line out of the line items.
    static func minorUnits(fromToken token: String, scaleDigits: Int = 2) -> Int? {
        var characters = Array(token)
        guard !characters.isEmpty else { return nil }

        var negative = false
        if characters[0] == "-" {
            negative = true
            characters.removeFirst()
        }
        while let first = characters.first, currencySymbols.contains(first) {
            characters.removeFirst()
        }
        guard !characters.isEmpty, characters.count <= 20 else { return nil }

        var integerDigits: [Character] = []
        var fractionDigits: [Character] = []
        var sawSeparator = false
        for character in characters {
            if character == "." || character == "," {
                if sawSeparator { return nil }
                sawSeparator = true
                continue
            }
            guard character.isASCII, character.isNumber else { return nil }
            if sawSeparator {
                fractionDigits.append(character)
            } else {
                integerDigits.append(character)
            }
        }
        // A bare integer is only an amount if a separator was present. `"2026"`
        // stays a year; `"2026.00"` becomes money.
        guard sawSeparator, !integerDigits.isEmpty else { return nil }
        // A thousands separator produces exactly three trailing digits, which is
        // never a minor-unit fraction — reject rather than read 1,250 as 1.25.
        guard fractionDigits.count >= 1, fractionDigits.count <= scaleDigits else { return nil }
        // 18 digits keeps the accumulation below `Int.max` (~9.22e18) with room
        // for the scale multiply that follows.
        guard integerDigits.count <= 18 - scaleDigits else { return nil }

        var value = 0
        for digit in integerDigits {
            guard let number = digit.wholeNumberValue else { return nil }
            value = Saturating.add(Saturating.multiply(value, 10), number)
        }
        var padded = fractionDigits
        while padded.count < scaleDigits { padded.append("0") }
        for digit in padded {
            guard let number = digit.wholeNumberValue else { return nil }
            value = Saturating.add(Saturating.multiply(value, 10), number)
        }
        return negative ? Saturating.multiply(value, -1) : value
    }

    /// Strips a leading or trailing quantity marker (`x2`, `2x`, `2 @`).
    func extractQuantity(from label: String) -> (label: String, count: Int) {
        var tokens = label.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return (label, 1) }

        for index in tokens.indices {
            // `tokens.indices` keeps this access in bounds by construction.
            let token = tokens[index]
            guard let count = Self.quantityValue(token), count > 0 else { continue }
            tokens.remove(at: index)
            let remainder = tokens.joined(separator: " ")
            return (remainder.isEmpty ? label : remainder, count)
        }
        return (label, 1)
    }

    static func quantityValue(_ token: String) -> Int? {
        var characters = Array(token.lowercased())
        guard characters.count >= 2, characters.count <= 6 else { return nil }
        if characters.first == "x" {
            characters.removeFirst()
        } else if characters.last == "x" {
            characters.removeLast()
        } else {
            return nil
        }
        guard !characters.isEmpty else { return nil }
        var value = 0
        for character in characters {
            guard character.isASCII, character.isNumber,
                  let digit = character.wholeNumberValue else { return nil }
            value = Saturating.add(Saturating.multiply(value, 10), digit)
        }
        return value
    }

    func normalizeLabel(_ label: String) -> String {
        String(label.uppercased().filter { $0.isLetter })
    }
}
