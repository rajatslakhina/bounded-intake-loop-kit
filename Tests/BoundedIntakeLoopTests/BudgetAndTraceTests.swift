import XCTest
@testable import BoundedIntakeLoop

final class BudgetLedgerTests: XCTestCase {

    func testToolClaimsNeverExceedTheLimit() async {
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: 3, turns: 10, contextUnits: 100))
        let first = await ledger.claimToolCalls(2)
        let second = await ledger.claimToolCalls(5)
        let third = await ledger.claimToolCalls(1)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 1, "a request larger than the remainder must be partially granted")
        XCTAssertEqual(third, 0)
        let snapshot = await ledger.snapshot
        XCTAssertEqual(snapshot.toolCallsUsed, 3)
        XCTAssertEqual(snapshot.toolCallsRemaining, 0)
    }

    func testNonPositiveClaimsAreIgnored() async {
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: 3, turns: 3, contextUnits: 10))
        let granted = await ledger.claimToolCalls(-5)
        XCTAssertEqual(granted, 0)
        let snapshot = await ledger.snapshot
        XCTAssertEqual(snapshot.toolCallsUsed, 0)
    }

    func testTurnClaimsStopAtTheCeiling() async {
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: 0, turns: 2, contextUnits: 10))
        let a = await ledger.claimTurn()
        let b = await ledger.claimTurn()
        let c = await ledger.claimTurn()
        XCTAssertEqual([a, b, c], [true, true, false])
    }

    func testContextClaimsSaturateRatherThanOverflow() async {
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: 0, turns: 1, contextUnits: 10))
        _ = await ledger.claimContextUnits(Int.max)
        let withinBudget = await ledger.claimContextUnits(Int.max)
        XCTAssertFalse(withinBudget)
        let snapshot = await ledger.snapshot
        XCTAssertEqual(snapshot.contextUnitsUsed, Int.max)
    }
}

/// A real concurrent writer, not a sequential loop with `async` in its name.
///
/// 512 tasks race on a ledger with 7 calls to give away. Actor isolation alone
/// is not enough to make this correct: if `claimToolCalls` ever gains an `await`
/// between reading the remainder and writing it back, several tasks observe the
/// same remainder, the total overshoots, and this test goes red.
final class ConcurrentBudgetClaimTests: XCTestCase {

    func testConcurrentClaimsSumToExactlyTheLimit() async {
        let limit = 7
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: limit, turns: 1, contextUnits: 1))

        let totalGranted = await withTaskGroup(of: Int.self) { group -> Int in
            for _ in 0..<512 {
                group.addTask { await ledger.claimToolCalls(1) }
            }
            var running = 0
            for await granted in group { running += granted }
            return running
        }

        XCTAssertEqual(totalGranted, limit)
        let snapshot = await ledger.snapshot
        XCTAssertEqual(snapshot.toolCallsUsed, limit)
    }

    func testConcurrentTurnClaimsSumToExactlyTheCeiling() async {
        let ceiling = 5
        let ledger = BudgetLedger(budget: IntakeBudget(toolCalls: 0, turns: ceiling, contextUnits: 1))

        let successes = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<256 {
                group.addTask { await ledger.claimTurn() }
            }
            var count = 0
            for await granted in group where granted { count += 1 }
            return count
        }

        XCTAssertEqual(successes, ceiling)
    }
}

final class IntakeTraceTests: XCTestCase {

    /// Feeds the recorder far more than it can hold and asserts it stayed
    /// bounded. An unbounded implementation passes every "does it record?" test
    /// and fails only this one.
    func testTraceStaysBoundedAndReportsWhatItDropped() async {
        let trace = IntakeTrace(capacity: 8)
        for index in 0..<1_000 {
            await trace.record(.turnStarted(index: index, mode: .allowed))
        }
        let stored = await trace.storedEventCount
        let dropped = await trace.droppedEventCount
        XCTAssertEqual(stored, 8)
        XCTAssertEqual(dropped, 992)

        let snapshot = await trace.snapshot
        XCTAssertEqual(snapshot.count, 9, "one marker plus the retained window")
        XCTAssertEqual(snapshot.first, .eventsDropped(count: 992))
        XCTAssertEqual(snapshot.last, .turnStarted(index: 999, mode: .allowed))
    }

    func testNothingIsMarkedDroppedWhenNothingWas() async {
        let trace = IntakeTrace(capacity: 8)
        await trace.record(.validationPassed)
        let snapshot = await trace.snapshot
        XCTAssertEqual(snapshot, [.validationPassed])
    }

    func testCapacityIsClampedToAtLeastOne() async {
        let trace = IntakeTrace(capacity: 0)
        await trace.record(.validationPassed)
        await trace.record(.validationFailed([.emptyRecord]))
        let stored = await trace.storedEventCount
        XCTAssertEqual(stored, 1)
    }
}
