import XCTest
@testable import BoundedIntakeLoop

final class ModeLadderTests: XCTestCase {

    func testDefaultLadderDescendsAndStaysDown() {
        let ladder = ModeLadder.default  // 1 required, 2 allowed
        let modes = (0..<6).map { ladder.mode(turnIndex: $0, toolCallsRemaining: 4) }
        XCTAssertEqual(modes, [.required, .allowed, .allowed, .none, .none, .none])
    }

    func testLadderNeverAscends() {
        let ladder = ModeLadder(requiredTurns: 2, allowedTurns: 3)
        let ranks: [ToolCallingMode: Int] = [.required: 0, .allowed: 1, .none: 2]
        var previous = 0
        for index in 0..<20 {
            let mode = ladder.mode(turnIndex: index, toolCallsRemaining: 10)
            let rank = ranks[mode] ?? -1
            XCTAssertGreaterThanOrEqual(rank, previous, "ladder went back up at turn \(index)")
            previous = rank
        }
    }

    func testExhaustedToolBudgetCollapsesEveryRungToNone() {
        let ladder = ModeLadder(requiredTurns: 5, allowedTurns: 5)
        for index in 0..<12 {
            XCTAssertEqual(ladder.mode(turnIndex: index, toolCallsRemaining: 0), ToolCallingMode.none)
        }
    }

    func testTerminalTurnIndexIsWhereTheLadderBottomsOut() {
        for required in 0...3 {
            for allowed in 0...3 {
                let ladder = ModeLadder(requiredTurns: required, allowedTurns: allowed)
                XCTAssertEqual(
                    ladder.mode(turnIndex: ladder.terminalTurnIndex, toolCallsRemaining: 99),
                    ToolCallingMode.none
                )
                if ladder.terminalTurnIndex > 0 {
                    XCTAssertNotEqual(
                        ladder.mode(turnIndex: ladder.terminalTurnIndex - 1, toolCallsRemaining: 99),
                        ToolCallingMode.none,
                        "the rung before the terminal one must still allow a tool call"
                    )
                }
            }
        }
    }

    func testNegativeTurnIndexIsTreatedAsTheFirstTurn() {
        XCTAssertEqual(ModeLadder.default.mode(turnIndex: -1, toolCallsRemaining: 4), .required)
    }

    func testDegenerateLadderIsImmediatelyTerminal() {
        let ladder = ModeLadder(requiredTurns: 0, allowedTurns: 0)
        XCTAssertEqual(ladder.terminalTurnIndex, 0)
        XCTAssertEqual(ladder.mode(turnIndex: 0, toolCallsRemaining: 99), ToolCallingMode.none)
    }
}
