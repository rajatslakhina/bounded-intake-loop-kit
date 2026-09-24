import XCTest
@testable import BoundedIntakeLoop

/// Every assertion here is on an input that would *trap* — not merely return a
/// wrong answer — if the guard it covers were deleted. A regression in
/// `Saturating` therefore crashes this test process rather than producing a red
/// assertion, which is the strongest failure signal a unit test can give.
final class SaturatingTests: XCTestCase {

    func testIntConversionRejectsNaN() {
        XCTAssertNil(Saturating.int(Double.nan))
        XCTAssertNil(Saturating.int(Double.signalingNaN))
    }

    func testIntConversionClampsInfinities() {
        XCTAssertEqual(Saturating.int(Double.infinity), Int.max)
        XCTAssertEqual(Saturating.int(-Double.infinity), Int.min)
    }

    func testIntConversionClampsOutOfRangeMagnitudes() {
        XCTAssertEqual(Saturating.int(1e300), Int.max)
        XCTAssertEqual(Saturating.int(-1e300), Int.min)
        // 2^63 exactly: the first `Double` above `Int.max`, and the value a
        // `>` comparison (rather than `>=`) would let through into a trap.
        XCTAssertEqual(Saturating.int(9_223_372_036_854_775_808.0), Int.max)
    }

    func testIntConversionIsExactInRange() {
        XCTAssertEqual(Saturating.int(0), 0)
        XCTAssertEqual(Saturating.int(-1.0), -1)
        XCTAssertEqual(Saturating.int(1810.0), 1810)
    }

    func testAdditionSaturates() {
        XCTAssertEqual(Saturating.add(Int.max, 1), Int.max)
        XCTAssertEqual(Saturating.add(Int.min, -1), Int.min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
    }

    func testMultiplicationSaturates() {
        XCTAssertEqual(Saturating.multiply(Int.max, 2), Int.max)
        XCTAssertEqual(Saturating.multiply(Int.max, -2), Int.min)
        XCTAssertEqual(Saturating.multiply(Int.min, -1), Int.max)
        XCTAssertEqual(Saturating.multiply(6, 7), 42)
    }

    func testSubtractionSaturates() {
        XCTAssertEqual(Saturating.subtract(Int.min, 1), Int.min)
        XCTAssertEqual(Saturating.subtract(Int.max, -1), Int.max)
        XCTAssertEqual(Saturating.subtract(10, 4), 6)
    }

    func testDivisionRefusesTheTwoTrappingCases() {
        XCTAssertNil(Saturating.divide(1, 0))
        XCTAssertNil(Saturating.divide(Int.min, -1))
        XCTAssertEqual(Saturating.divide(450, 2), 225)
    }

    /// `Swift.abs(Int.min)` traps. Both of these would crash the test process
    /// if the guard were removed rather than merely returning a wrong number.
    func testAbsoluteValueAndDistanceDoNotTrapAtIntMin() {
        XCTAssertEqual(Saturating.absoluteValue(Int.min), Int.max)
        XCTAssertEqual(Saturating.absoluteValue(-7), 7)
        XCTAssertEqual(Saturating.absoluteValue(7), 7)
        XCTAssertEqual(Saturating.distance(Int.min, 0), Int.max)
        XCTAssertEqual(Saturating.distance(0, Int.max), Int.max)
        XCTAssertEqual(Saturating.distance(1811, 1810), 1)
        XCTAssertEqual(Saturating.distance(1810, 1811), 1)
    }

    func testUsableAmountRejectsNonFiniteAndOversizedValues() {
        XCTAssertFalse(Saturating.isUsableAmount(.nan))
        XCTAssertFalse(Saturating.isUsableAmount(.infinity))
        XCTAssertFalse(Saturating.isUsableAmount(1e18))
        XCTAssertTrue(Saturating.isUsableAmount(18.10))
    }

    // MARK: - Money

    func testMoneyFromDoubleRejectsUnrepresentableInput() {
        XCTAssertNil(Money.minorUnits(from: .nan))
        XCTAssertNil(Money.minorUnits(from: .infinity))
        XCTAssertNil(Money.minorUnits(from: 1.0, scale: 0))
    }

    func testMoneyRoundsRatherThanTruncates() {
        // The specific value a model hands back after reading "12.99".
        XCTAssertEqual(Money.minorUnits(from: 12.989999), 1299)
        XCTAssertEqual(Money.minorUnits(from: 12.994), 1299)
        XCTAssertEqual(Money.minorUnits(from: 12.995), 1300)
    }

    func testMoneyStringDoesNotTrapOnIntMin() {
        // `abs(Int.min)` traps. This asserts the implementation used `magnitude`.
        XCTAssertTrue(Money.string(minorUnits: Int.min).hasPrefix("-"))
        XCTAssertEqual(Money.string(minorUnits: 1810), "18.10")
        XCTAssertEqual(Money.string(minorUnits: 5), "0.05")
        XCTAssertEqual(Money.string(minorUnits: -5), "-0.05")
        XCTAssertEqual(Money.string(minorUnits: 0), "0.00")
    }
}
