import XCTest
@testable import BoundedIntakeLoop

final class RecordValidatorTests: XCTestCase {

    private let good = IntakeScenarioCatalog.expectedRecord()

    func testTheFixtureRecordIsCleanUnderStrictPolicy() {
        XCTAssertEqual(RecordValidator(policy: .strict).validate(good), [])
    }

    /// The reconciliation check, fed a record broken by exactly one minor unit.
    ///
    /// This is the anti-vacuous form: a total check that only compared a value
    /// to itself, or that compared against a tolerance the implementation
    /// derived from the same numbers, would pass the test above and fail here.
    func testOneCentOfDriftIsRejectedUnderStrictPolicy() {
        let broken = IntakeRecord(
            barcode: good.barcode,
            merchant: good.merchant,
            lineItems: good.lineItems,
            declaredTotalMinorUnits: (good.declaredTotalMinorUnits ?? 0) + 1,
            currencyCode: good.currencyCode
        )
        XCTAssertEqual(
            RecordValidator(policy: .strict).validate(broken),
            [.totalMismatch(declared: 1811, computed: 1810, toleranceMinorUnits: 0)]
        )
    }

    func testTheSameDriftPassesUnderTheReceiptFriendlyTolerance() {
        let drifted = IntakeRecord(
            lineItems: good.lineItems,
            declaredTotalMinorUnits: (good.declaredTotalMinorUnits ?? 0) + 99,
            currencyCode: good.currencyCode
        )
        XCTAssertEqual(RecordValidator(policy: .receiptFriendly).validate(drifted), [])
    }

    func testRejectsMalformedCurrencyCodes() {
        for code in ["", "us", "USDX", "us1", "usd"] {
            let record = IntakeRecord(merchant: "X", currencyCode: code)
            XCTAssertTrue(
                RecordValidator().validate(record).contains(.malformedCurrencyCode(code)),
                "\(code) should not be accepted as ISO 4217"
            )
        }
    }

    func testRejectsNonPositiveQuantitiesAndNegativePrices() {
        let record = IntakeRecord(
            lineItems: [
                LineItem(label: "Free", quantity: 0, unitPriceMinorUnits: 100),
                LineItem(label: "Refund", quantity: 1, unitPriceMinorUnits: -250)
            ],
            currencyCode: "USD"
        )
        let failures = RecordValidator().validate(record)
        XCTAssertTrue(failures.contains(.nonPositiveQuantity(label: "Free", quantity: 0)))
        XCTAssertTrue(failures.contains(.negativeUnitPrice(label: "Refund", minorUnits: -250)))
    }

    func testCapsLineItemCount() {
        let items = (0..<300).map { LineItem(label: "i\($0)", quantity: 1, unitPriceMinorUnits: 1) }
        let record = IntakeRecord(lineItems: items, currencyCode: "USD")
        let failures = RecordValidator(policy: ValidationPolicy(maximumLineItems: 256)).validate(record)
        XCTAssertTrue(failures.contains(.tooManyLineItems(count: 300, limit: 256)))
    }

    func testRejectsAnEmptyRecord() {
        let record = IntakeRecord(currencyCode: "USD")
        XCTAssertTrue(RecordValidator().validate(record).contains(.emptyRecord))
    }

    /// A quantity of `Int.max` at a non-zero price overflows the extended price.
    /// The record must be rejected, and the validator must not trap getting there.
    func testSurvivesAnAbsurdQuantityWithoutTrapping() {
        let record = IntakeRecord(
            lineItems: [LineItem(label: "Glitch", quantity: Int.max, unitPriceMinorUnits: 999)],
            declaredTotalMinorUnits: 100,
            currencyCode: "USD"
        )
        let failures = RecordValidator().validate(record)
        XCTAssertFalse(failures.isEmpty)
        XCTAssertEqual(record.computedTotalMinorUnits, Int.max)
    }
}

final class ReceiptTextParserTests: XCTestCase {

    func testParsesTheFixtureIntoTheExpectedLineItems() {
        let parsed = ReceiptTextParser().parse(IntakeScenarioCatalog.receiptLines)
        XCTAssertEqual(parsed.merchant, "ACME MARKET")
        XCTAssertEqual(parsed.declaredTotalMinorUnits, 1810)
        XCTAssertEqual(parsed.lineItems, IntakeScenarioCatalog.expectedRecord().lineItems)
    }

    func testSubtotalIsSkippedSoTheSumStillReconciles() {
        let parsed = ReceiptTextParser().parse(IntakeScenarioCatalog.receiptLines)
        XCTAssertFalse(parsed.lineItems.contains { $0.label.uppercased().contains("SUBTOTAL") })
        let summed = parsed.lineItems.reduce(0) { $0 + $1.extendedMinorUnits }
        XCTAssertEqual(summed, parsed.declaredTotalMinorUnits)
    }

    func testBareIntegersAreNotTreatedAsMoney() {
        XCTAssertNil(ReceiptTextParser.minorUnits(fromToken: "2026"))
        XCTAssertNil(ReceiptTextParser.minorUnits(fromToken: "12"))
        XCTAssertEqual(ReceiptTextParser.minorUnits(fromToken: "12.00"), 1200)
    }

    func testThousandsSeparatorsAreRejectedRatherThanMisread() {
        // "1,250" must not become 1.25 — that is a 100× error hiding as a parse.
        XCTAssertNil(ReceiptTextParser.minorUnits(fromToken: "1,250"))
        XCTAssertEqual(ReceiptTextParser.minorUnits(fromToken: "1,25"), 125)
    }

    func testRejectsGarbageTokens() {
        for token in ["", "-", "..", "1..2", "abc", "1.2.3", "$"] {
            XCTAssertNil(
                ReceiptTextParser.minorUnits(fromToken: token),
                "\(token) should not parse as an amount"
            )
        }
    }

    func testHandlesCurrencySymbolsAndNegatives() {
        XCTAssertEqual(ReceiptTextParser.minorUnits(fromToken: "$3.49"), 349)
        XCTAssertEqual(ReceiptTextParser.minorUnits(fromToken: "-1.00"), -100)
        XCTAssertEqual(ReceiptTextParser.minorUnits(fromToken: "€0.5"), 50)
    }

    func testQuantityMarkersAreLifted() {
        XCTAssertEqual(ReceiptTextParser.quantityValue("x2"), 2)
        XCTAssertEqual(ReceiptTextParser.quantityValue("3x"), 3)
        XCTAssertNil(ReceiptTextParser.quantityValue("Milk"))
        XCTAssertNil(ReceiptTextParser.quantityValue("x"))
    }

    /// A quantity that does not divide the printed extended price evenly is
    /// reported as one unit at the printed price, because a rounded unit price
    /// would break reconciliation against the very total it was derived from.
    func testUnevenQuantityFallsBackToASingleUnit() {
        let parsed = ReceiptTextParser().parse(["Bagels x3 1.00"])
        XCTAssertEqual(parsed.lineItems, [LineItem(label: "Bagels", quantity: 1, unitPriceMinorUnits: 100)])
    }

    func testEmptyAndOversizedInputAreBounded() {
        XCTAssertEqual(ReceiptTextParser().parse([]).lineItems, [])
        let flood = Array(repeating: "Item 1.00", count: 5_000)
        let parsed = ReceiptTextParser(maximumLines: 100).parse(flood)
        XCTAssertEqual(parsed.lineItems.count, 100)
    }
}
