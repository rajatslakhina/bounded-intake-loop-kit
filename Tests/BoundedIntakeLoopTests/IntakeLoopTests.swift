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

    /// **The headline bound, measured from outside the ledger.**
    ///
    /// Asserting `budget.toolCallsUsed <= budget.toolCallsLimit` proves nothing:
    /// `claimToolCalls` returns `min(request, remaining)`, so that comparison is
    /// true by construction no matter how the loop behaves. The only honest
    /// check counts the work that actually happened, using counters the ledger
    /// does not own — the tool's own entry count and the model's own turn count.
    ///
    /// The model here asks for a *different* invocation every turn, so nothing
    /// is coalesced and every request is a genuine spend decision. If the ledger
    /// were ignored, the tool would be entered once per turn; it is entered
    /// exactly `budget.toolCalls` times.
    func testTheToolBoundIsMeasurableFromOutsideTheLedger() async {
        let tool = CountingGroundingTool(
            name: StandardTool.recognizeText,
            payload: .recognizedText(IntakeScenarioCatalog.receiptLines)
        )
        let script: [ModelTurn] = (0..<50).map { index in
            .callTools([ToolInvocation(tool: StandardTool.recognizeText, argument: "region-\(index)")])
        }
        let model = ScriptedIntakeModel(script: script, whenExhausted: .repeatLast)
        let budget = IntakeBudget(toolCalls: 3, turns: 40, contextUnits: 10_000_000)
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: [tool]),
            fallback: DeterministicIntake(currencyCode: "USD"),
            ladder: ModeLadder(requiredTurns: 1, allowedTurns: 50),
            budget: budget
        )

        let result = await loop.run(attachment)

        let toolEntries = await tool.invocationCount
        XCTAssertEqual(toolEntries, budget.toolCalls, "the tool ran more times than the budget allowed")
        // With the tool budget spent, the ladder collapses to `.none`, and the
        // model's next tool request is a contract violation — so the run ends
        // far short of its 40-turn ceiling.
        XCTAssertEqual(
            result.termination,
            .contractViolation(.calledToolWhileModeWasNone(tool: StandardTool.recognizeText))
        )
        let turnsServed = await model.turnsServed
        XCTAssertEqual(turnsServed, 4)
    }

    /// The turn ceiling, measured the same way — against the model's own count
    /// of how many times it was asked, not against the ledger's own snapshot.
    ///
    /// This model emits an invalid record forever and never calls a tool, so the
    /// tool budget never moves and the ladder is configured never to bottom out.
    /// The turn ceiling is the only thing left that can stop it.
    func testTheTurnBoundIsMeasurableFromOutsideTheLedger() async {
        let broken = IntakeRecord(
            barcode: IntakeScenarioCatalog.hallucinatedBarcodeValue,
            merchant: "ACME MARKET",
            currencyCode: "USD"
        )
        let model = ScriptedIntakeModel(script: [.emit(broken)], whenExhausted: .repeatLast)
        let budget = IntakeBudget(toolCalls: 4, turns: 5, contextUnits: 10_000_000)
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD"),
            ladder: ModeLadder(requiredTurns: 0, allowedTurns: 50),
            budget: budget
        )

        let result = await loop.run(attachment)

        let turnsServed = await model.turnsServed
        XCTAssertEqual(turnsServed, budget.turns, "the model was asked more times than the ceiling allowed")
        XCTAssertEqual(result.termination, .turnBudgetExhausted)
    }

    /// Each scenario spends exactly what the catalog says it spends.
    ///
    /// These are hand-written numbers tighter than the ledger's ceiling, so they
    /// are falsifiable: if coalescing broke, the runaway scenario's 1 would
    /// become 4 and this would go red.
    func testEveryScenarioSpendsExactlyWhatTheCatalogClaims() async {
        for scenario in IntakeScenario.allCases {
            let result = await IntakeScenarioCatalog.loop(for: scenario).run(attachment)
            XCTAssertEqual(
                result.budget.toolCallsUsed,
                IntakeScenarioCatalog.expectedToolCalls(for: scenario),
                "\(scenario.rawValue) spent a different number of tool calls than the catalog claims"
            )
        }
    }

    /// A cancelled run stops at the next turn boundary and still returns
    /// whatever the evidence supports, rather than throwing the read away.
    func testACancelledRunStopsAndKeepsWhatItHas() async {
        let model = ScriptedIntakeModel(
            script: [.callTools([ToolInvocation(tool: StandardTool.recognizeText)])],
            whenExhausted: .repeatLast
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: IntakeScenarioCatalog.standardTools()),
            fallback: DeterministicIntake(currencyCode: "USD"),
            ladder: ModeLadder(requiredTurns: 1, allowedTurns: 50),
            budget: IntakeBudget(toolCalls: 8, turns: 100, contextUnits: 10_000_000)
        )

        // Local copies: capturing `self.attachment` would pull the non-Sendable
        // XCTestCase into the task.
        let photo = IntakeScenarioCatalog.attachment
        let task = Task { await loop.run(photo) }
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertLessThan(result.budget.turnsUsed, 100, "cancellation must beat the turn ceiling here")
        // The "keeps what it has" half, which is the part the README promises.
        // An implementation that returned `.cancelled` and skipped the fallback
        // would satisfy the two assertions above and fail these.
        XCTAssertNotNil(result.record, "a cancelled run must not discard the evidence it gathered")
        XCTAssertEqual(result.provenance, .deterministicFallback)
        XCTAssertEqual(result.record?.declaredTotalMinorUnits, 1810)
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

        // Two distinct limits, and conflating them would hide a real problem:
        // requests past `maximumToolRequestsPerTurn` were never read (a
        // truncation), while the ones the ledger refused were read and declined
        // (a spending decision).
        XCTAssertTrue(
            result.trace.contains(.toolRequestsTruncated(requested: 20, considered: 8)),
            "the trace must say the list was truncated, not silently shortened"
        )
        let declined = result.trace.filter {
            if case .toolRequested(_, let granted) = $0 { return !granted }
            return false
        }
        XCTAssertEqual(declined.count, 5, "8 considered minus the 3 the budget paid for")
        let completed = result.trace.filter {
            if case .toolCompleted = $0 { return true }
            return false
        }
        XCTAssertEqual(completed.count, 3)
    }

    /// "Coalesced repeats cost nothing" has to hold *within* a turn too.
    ///
    /// A model that names the same uncached invocation four times in one turn
    /// must be billed once, not four times — otherwise the guarantee is really
    /// "repeats are free across turns", which is not what the design claims and
    /// not what a model in a repetition loop actually does.
    func testDuplicateRequestsWithinOneTurnAreBilledOnce() async {
        let tool = CountingGroundingTool(
            name: StandardTool.recognizeText,
            payload: .recognizedText(IntakeScenarioCatalog.receiptLines)
        )
        let invocation = ToolInvocation(tool: StandardTool.recognizeText)
        let good = IntakeScenarioCatalog.expectedRecord()
        let model = ScriptedIntakeModel(
            script: [.callTools([invocation, invocation, invocation, invocation]), .emit(good)],
            whenExhausted: .emit(good)
        )
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: [tool]),
            fallback: DeterministicIntake(currencyCode: "USD"),
            budget: IntakeBudget(toolCalls: 4, turns: 6, contextUnits: 1_000_000)
        )

        let result = await loop.run(attachment)

        let entries = await tool.invocationCount
        XCTAssertEqual(entries, 1, "the tool must run once for four identical requests")
        XCTAssertEqual(result.budget.toolCallsUsed, 1, "and only one of them may cost budget")
        XCTAssertEqual(result.provenance, .model)
    }

    /// The per-turn cap, measured against the tool's own entry count.
    func testAnAbsurdToolRequestListIsBoundedBeforeItIsProcessed() async {
        let tool = CountingGroundingTool(
            name: StandardTool.recognizeText,
            payload: .recognizedText(IntakeScenarioCatalog.receiptLines)
        )
        let invocations = (0..<50_000).map {
            ToolInvocation(tool: StandardTool.recognizeText, argument: "r\($0)")
        }
        let model = ScriptedIntakeModel(script: [.callTools(invocations)], whenExhausted: .fail)
        let loop = IntakeLoop(
            model: model,
            registry: ToolRegistry(tools: [tool]),
            fallback: DeterministicIntake(currencyCode: "USD"),
            budget: IntakeBudget(toolCalls: 4, turns: 6, contextUnits: 10_000_000),
            traceCapacity: 64,
            maximumToolRequestsPerTurn: 2
        )

        let result = await loop.run(attachment)

        let entries = await tool.invocationCount
        XCTAssertEqual(entries, 2, "only the considered prefix may reach the tool")
        XCTAssertTrue(
            result.trace.contains(.toolRequestsTruncated(requested: 50_000, considered: 2))
        )
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
