import Foundation

/// GTIN (UPC-A / EAN-8 / EAN-13 / GTIN-14) check-digit arithmetic.
///
/// This is the cheapest useful oracle in the whole pipeline. A language model
/// reading digits off a curved, glare-lit barcode will transpose two of them and
/// return a string that *looks* exactly like a barcode; the mod-10 check digit
/// catches every single-digit substitution and most transpositions for free,
/// without a network call and without asking the model to check its own work.
///
/// Checking the model's output against arithmetic it cannot influence is the
/// difference between a validated record and a confident one.
public enum GTIN {

    /// Lengths defined by the GS1 General Specifications. A string of any other
    /// length is not a GTIN, whatever the model called it.
    public static let supportedLengths: Set<Int> = [8, 12, 13, 14]

    /// Computes the mod-10 check digit for the payload (all digits *except* the
    /// final check digit).
    ///
    /// GS1 weights run 3,1,3,1… from the rightmost payload digit leftward, which
    /// is why the weight is chosen by index parity counted from the end rather
    /// than from the start — getting that backwards yields a checker that passes
    /// EAN-13 and silently rejects every UPC-A.
    ///
    /// Returns `nil` if the payload contains a non-digit.
    public static func checkDigit(forPayload payload: some StringProtocol) -> Int? {
        var sum = 0
        // `reversed()` on a collection of digits is bounded by the payload length,
        // which callers cap before we get here.
        for (offsetFromRight, character) in payload.reversed().enumerated() {
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                return nil
            }
            let weight = offsetFromRight.isMultiple(of: 2) ? 3 : 1
            sum = Saturating.add(sum, Saturating.multiply(digit, weight))
        }
        // `sum` is bounded by 9 * 3 * 13 = 351 for any supported length, so the
        // modulo below cannot be reached with a saturated value in practice; the
        // saturating adds above exist so that a caller who ignores the length cap
        // still cannot trap.
        let remainder = sum % 10
        return remainder == 0 ? 0 : 10 - remainder
    }

    /// Validates a complete GTIN string, returning the specific failure rather
    /// than a bare `false` so the caller can decide whether to re-ground with the
    /// barcode tool or give up on the field.
    public static func validate(_ barcode: String) -> ValidationFailure? {
        let length = barcode.count
        guard supportedLengths.contains(length) else {
            return .barcodeUnsupportedLength(barcode: barcode, length: length)
        }
        // Length is one of 8/12/13/14 here, so `dropLast()` and `last` are both
        // guaranteed non-empty; no force-unwrap is used regardless.
        guard let lastCharacter = barcode.last,
              let found = lastCharacter.wholeNumberValue,
              (0...9).contains(found) else {
            return .barcodeNonNumeric(barcode: barcode)
        }
        guard let expected = checkDigit(forPayload: barcode.dropLast()) else {
            return .barcodeNonNumeric(barcode: barcode)
        }
        guard expected == found else {
            return .barcodeCheckDigitMismatch(barcode: barcode, expected: expected, found: found)
        }
        return nil
    }
}
