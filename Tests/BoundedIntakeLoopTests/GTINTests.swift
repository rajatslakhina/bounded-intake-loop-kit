import XCTest
@testable import BoundedIntakeLoop

final class GTINTests: XCTestCase {

    func testAcceptsKnownGoodCodes() {
        XCTAssertNil(GTIN.validate("4006381333931"))   // EAN-13
        XCTAssertNil(GTIN.validate("036000291452"))    // UPC-A
        XCTAssertNil(GTIN.validate("96385074"))        // EAN-8
    }

    func testRejectsASingleWrongCheckDigit() {
        XCTAssertEqual(
            GTIN.validate("4006381333932"),
            .barcodeCheckDigitMismatch(barcode: "4006381333932", expected: 1, found: 2)
        )
    }

    func testRejectsNonGTINLengths() {
        XCTAssertEqual(
            GTIN.validate("12345"),
            .barcodeUnsupportedLength(barcode: "12345", length: 5)
        )
        XCTAssertEqual(
            GTIN.validate(""),
            .barcodeUnsupportedLength(barcode: "", length: 0)
        )
    }

    func testRejectsNonNumericPayloads() {
        XCTAssertEqual(
            GTIN.validate("40063813339A1"),
            .barcodeNonNumeric(barcode: "40063813339A1")
        )
        XCTAssertEqual(
            GTIN.validate("400638133393X"),
            .barcodeNonNumeric(barcode: "400638133393X")
        )
    }

    /// The failure mode the checker exists for: a model transposing two adjacent
    /// digits while reading a curved label.
    ///
    /// Not every transposition changes the mod-10 sum — swapping digits that
    /// differ by five leaves it unchanged — so the pair chosen here differs by
    /// 3, which does. The test asserts the *specific* expected/found pair, so a
    /// checker that merely returned "invalid" for everything would not satisfy
    /// it either.
    func testDetectsAdjacentTransposition() {
        // 4006381333931 → swap the '6' and the '3' that follow "400".
        let transposed = "4003681333931"
        guard case .barcodeCheckDigitMismatch(_, let expected, let found)? =
                GTIN.validate(transposed) else {
            return XCTFail("transposition slipped past the check digit")
        }
        XCTAssertEqual(found, 1)
        XCTAssertNotEqual(expected, found)
    }

    /// A deliberately broken checker, run side by side with the real one.
    ///
    /// GS1 weights 3,1,3,1… counted from the **right** of the payload. Counting
    /// from the left is the single most common way to get this wrong, and for an
    /// even-length payload it produces a different digit. This test builds the
    /// barcode the broken implementation would call valid and asserts the real
    /// checker rejects it — so the test fails if someone ever "simplifies"
    /// `checkDigit` into the left-weighted version.
    func testRejectsTheCodeALeftWeightedCheckerWouldAccept() {
        let payload = "400638133393"  // 12 digits, even length
        let leftWeighted = Self.leftWeightedCheckDigit(payload)
        guard let correct = GTIN.checkDigit(forPayload: payload) else {
            return XCTFail("check digit could not be computed for a numeric payload")
        }
        XCTAssertNotEqual(
            leftWeighted, correct,
            "the two weightings agree on this payload, so it proves nothing — pick another"
        )
        XCTAssertNotNil(GTIN.validate(payload + String(leftWeighted)))
        XCTAssertNil(GTIN.validate(payload + String(correct)))
    }

    private static func leftWeightedCheckDigit(_ payload: String) -> Int {
        var sum = 0
        for (index, character) in payload.enumerated() {
            let digit = character.wholeNumberValue ?? 0
            sum += digit * (index.isMultiple(of: 2) ? 3 : 1)
        }
        let remainder = sum % 10
        return remainder == 0 ? 0 : 10 - remainder
    }
}
