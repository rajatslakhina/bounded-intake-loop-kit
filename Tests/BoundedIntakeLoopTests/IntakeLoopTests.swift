import XCTest
@testable import BoundedIntakeLoop

final class IntakeLoopTests: XCTestCase {

    private let attachment = IntakeScenarioCatalog.attachment

    // MARK: - The five shipped scenarios

    func testGroundedReadIsAttributedToTheModel() async {
        let result = await IntakeScenarioCatalog.loop(for: .groundedThenEmit).run(attachment)
        XCTAssertEqual(result.provenance, .model)
        XCTAssertEqual(result.record, IntakeScenarioCatalog.expectedRecord())
        XCTAssertEqual(result.termination, .modelEmittedValidRecord)
        XCTAssertEqual(result.outstandingFailures, [])
        XCTAssertEqual(result.budget.toolCallsUsed, 2)
        XCTAssertTrue(result.isTrustworthy)
    }

    func testAnUnavailableModelStillProducesARecordFromOCR() async {
        let result = await IntakeScenarioCatalog.loop(for: .modelUnavailable).run(attachment)
        XCTAssertEqual(result.provenance, .deterministicFallback)
        XCTAssertEqual(result.record, IntakeScenarioCatalog.expectedRecord())
        XCTAssertEqual(result.termination, .modelUnavailable("model not available on this device"))
        XCTAssertEqual(result.outstandingFailures, [])
        XCTAssertTrue(result.isTrustworthy, "a clean fallback record is still trustworthy")
    }

    /// The headline claim: a model that never stops asking cannot make the loop
    /// run forever. The turn ceiling is the only thing that can stop this run,
    /// because the ladder for this scenario bottoms out past the ceiling and
    /// every repeat is coalesced so the tool budget never moves.
    func testARunawayModelIsStoppedByTheTurnCeiling() async {
        let result = await IntakeScenarioCatalog.loop(for: .runawayModel).run(attachment)
        XCTAssertEqual(result.termination, .turnBudgetExhausted)
        XCTAssertEqual(result.budget.turnsUsed, result.budget.turnsLimit)
        XCTAssertEqual(
            result.budget.toolCallsUsed, 1,
            "the same invocation repeated must be served from the coalescing cache"
        )
        XCTAssertEqual(result.provenance, .deterministicFallback)
        XCTAssertNotNil(result.record)
        // OCR ran but the barcode reader never did, so the field is honestly absent.
        XCTAssertNil(result.record?.barcode)
        XCTAssertEqual(result.record?.declaredTotalMinorUnits, 1810)
    }

    func testAHallucinatedBarcodeIsRejectedEveryTimeAndThenDropped() async {
        let result = await IntakeScenarioCatalog.loop(for: .hallucinatedBarcode).run(attachment)
        guard case .validationExhausted(let failures) = result.termination else {
            return XCTFail("expected validation to be the reason the loop stopped, got \(result.termination)")
        }
        XCTAssertEqual(failures, [
            .barcodeCheckDigitMismatch(
                barcode: IntakeScenarioCatalog.hallucinatedBarcodeValue,
                expected: 1,
                found: 2
            )
        ])
        XCTAssertEqual(result.provenance, .deterministicFallback)
        XCTAssertEqual(
            result.record?.barcode, IntakeScenarioCatalog.validBarcode,
            "the fallback must use the barcode the reader actually saw, not the one the model claimed"
        )
        XCTAssertEqual(result.outstandingFailures, [])
    }

    func testAnUnregisteredToolEndsTheRunImmediately() async {
        let result = await IntakeScenarioCatalog.loop(for: .contractViolation).run(attachment)
        XCTAssertEqual(
            result.termination,
            .contractViolation(.calledUnregisteredTool(tool: "summarizeReceipt"))
        )
        XCTAssertEqual(result.provenance, .deterministicFallback)
        XCTAssertEqual(result.record, IntakeScenarioCatalog.expectedRecord())
    }

    func testEveryShippedScenarioMatchesItsPinnedTermination() async {
        for scenario in IntakeScenario.allCases {
            let result = await IntakeScenarioCatalog.loop(for: scenario).run(attachment)
            XCTAssertEqual(
                result.termination,
                IntakeScenarioCatalog.expectedTermination(for: scenario),
                "\(scenario.rawValue) terminated differently than the catalog claims"
            )
            XCTAssertEqual(
                result.provenance,
                IntakeScenarioCatalog.expectedProvenance(for: scenario),
                "\(scenario.rawValue) provenance drifted from the catalog"
            )
        }
    }

    /// The bound, asserted across every scenario rather than argued in a comment.
    func testNoScenarioEverExceedsItsBudget() async {
        for scenario in IntakeScenario.allCases {
            let result = await IntakeScenarioCatalog.loop(for: scenario).run(attachment)
            XCTAssertLessThanOrEqual(
                result.budget.toolCallsUsed, result.budget.toolCallsLimit,
                "\(scenario.rawValue) overspent its tool budget"
            )
            XCTAssertLessThanOrEqual(
                result.budget.turnsUsed, result.budget.turnsLimit,
                "\(scenario.rawValue) overspent its turn budget"
            )
        }
    }

    // MARK: - Contract violations the catalog does not cover

    func testCallingAToolAfterTheLadderBottomsOutIsAViolation() async {
        // Default ladder, so `.none` arrives at turn 3, well inside the 6-turn
        // ceiling: the ladder, not the turn budget, must be what fires.
        let model = ScriptedIntakeModel(
            script: [.callTools([ToolInvocation(tool: StandardTool.recognizeText, argument: "0")])],
            whenExhausted: .repeatLast
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD"),
            ladder: .default,
            budget: IntakeBudget(toolCalls: 8, turns: 20, contextUnits: 100_000)
        )
        let result = await loop.run(attachment)
        XCTAssertEqual(
            result.termination,
            .contractViolation(.calledToolWhileModeWasNone(tool: StandardTool.recognizeText))
        )
        XCTAssertLessThan(result.budget.turnsUsed, 20)
    }

    func testEmittingBeforeGroundingIsAViolation() async {
        let model = ScriptedIntakeModel(
            script: [.emit(IntakeScenarioCatalog.expectedRecord())],
            whenExhausted: .fail
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD")
        )
        let result = await loop.run(attachment)
        XCTAssertEqual(result.termination, .contractViolation(.emittedWhileModeWasRequired))
        // No evidence was gathered by the model, so the loop grounds the photo
        // itself before falling back — which is why this ends with a record.
        XCTAssertEqual(result.record, IntakeScenarioCatalog.expectedRecord())
    }

    func testAnEmptyToolListIsAViolation() async {
        let model = ScriptedIntakeModel(script: [.callTools([])], whenExhausted: .fail)
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD")
        )
        let result = await loop.run(attachment)
        XCTAssertEqual(result.termination, .contractViolation(.requestedZeroTools))
    }

    // MARK: - Budget pressure

    /// A model that asks for more distinct tools in one turn than the budget
    /// allows. The excess must be declined and traced, never silently run.
    func testExcessToolRequestsInOneTurnArePartiallyGrantedAndTraced() async {
        let invocations = (0..<20).map {
            ToolInvocation(tool: StandardTool.recognizeText, argument: "region-\($0)")
        }
        let model = ScriptedIntakeModel(
            script: [.callTools(invocations), .emit(IntakeScenarioCatalog.expectedRecord())],
            whenExhausted: .emit(IntakeScenarioCatalog.expectedRecord())
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD"),
            budget: IntakeBudget(toolCalls: 3, turns: 6, contextUnits: 1_000_000),
            traceCapacity: 256
        )
        let result = await loop.run(attachment)

        XCTAssertEqual(result.budget.toolCallsUsed, 3)
        let declined = result.trace.filter {
            if case .toolRequested(_, let granted) = $0 { return !granted }
            return false
        }
        XCTAssertEqual(declined.count, 17)
        let completed = result.trace.filter {
            if case .toolCompleted = $0 { return true }
            return false
        }
        XCTAssertEqual(completed.count, 3)
    }

    func testAContextCeilingOfZeroStopsTheRunBeforeTheModelIsCalled() async {
        let model = ScriptedIntakeModel(
            script: [.emit(IntakeScenarioCatalog.expectedRecord())],
            whenExhausted: .fail
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD"),
            budget: IntakeBudget(toolCalls: 4, turns: 6, contextUnits: 0)
        )
        let result = await loop.run(attachment)
        XCTAssertEqual(result.termination, .contextBudgetExhausted)
        let turns = await model.turnsServed
        XCTAssertEqual(turns, 0, "the ceiling must be checked before the provider is invoked")
    }

    // MARK: - No model at all

    func testNoModelConfiguredFallsStraightThroughToTheDeterministicPath() async {
        let loop = IntakeLoop(
            model: nil,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD")
        )
        let result = await loop.run(attachment)
        XCTAssertEqual(result.termination, .modelUnavailable("no model configured"))
        XCTAssertEqual(result.record, IntakeScenarioCatalog.expectedRecord())
        XCTAssertEqual(result.provenance, .deterministicFallback)
    }

    func testWithNoEvidenceAtAllTheResultIsHonestlyEmpty() async {
        let loop = IntakeLoop(
            model: nil,
            registry: ToolRegistry(tools: []),
            fallback: DeterministicIntake(currencyCode: "USD")
        )
        let result = await loop.run(attachment)
        XCTAssertNil(result.record)
        XCTAssertEqual(result.provenance, Provenance.none)
        XCTAssertFalse(result.isTrustworthy)
    }

    func testTheFallbackRefusesEvidenceThatFailsItsOwnChecks() async {
        let loop = IntakeLoop(
            model: nil,
            registry: ToolRegistry(tools: [
                StaticGroundingTool(
                    name: StandardTool.readBarcode,
                    payload: .barcode(IntakeScenarioCatalog.hallucinatedBarcodeValue)
                )
            ]),
            fallback: DeterministicIntake(currencyCode: "USD")
        )
        let result = await loop.run(attachment)
        XCTAssertNil(
            result.record,
            "a barcode that fails its check digit is not evidence, whoever produced it"
        )
    }
}

final class IntakeEvalHarnessTests: XCTestCase {

    func testTheShippedEvalSuitePasses() async {
        let report = await IntakeEvalHarness().run(IntakeScenarioCatalog.evalCases())
        XCTAssertEqual(report.totalCount, IntakeScenario.allCases.count)
        XCTAssertTrue(report.passed, "failures: \(report.outcomes.flatMap(\.failures))")
    }

    /// The harness, fed a deliberately wrong expectation, must go red.
    ///
    /// Without this, "the eval suite passes" is a statement about the
    /// expectations, not about the loop — a harness that returned `passed` for
    /// everything would satisfy the test above and nothing else.
    func testTheHarnessFailsWhenAnExpectationIsWrong() async {
        let wrong = IntakeEvalCase(
            name: "deliberately wrong",
            loop: IntakeScenarioCatalog.loop(for: .modelUnavailable),
            attachment: IntakeScenarioCatalog.attachment,
            expectedProvenance: .model,   // it is a fallback, and the harness must say so
            expectedRecord: .some(nil),   // it does produce a record
            maximumToolCalls: 0,          // it uses two
            requiresCleanValidation: true
        )
        let outcome = await IntakeEvalHarness().run(wrong)
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.failures.count, 3, "each wrong expectation must be reported separately")
    }
}
