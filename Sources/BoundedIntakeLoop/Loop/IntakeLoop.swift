import Foundation

/// A bounded multimodal agent loop.
///
/// The whole design is one claim: **an agent loop inside a consumer app must
/// terminate for reasons the model does not control.** Three independent
/// mechanisms enforce it, and any one of them alone is sufficient:
///
/// 1. The ``ModeLadder`` descends `required` → `allowed` → `none` on the turn
///    index. Once it reaches `.none`, a tool call is a contract violation and
///    ends the run.
/// 2. ``BudgetLedger`` caps tool calls, turns and context units, and every claim
///    is a single non-suspending actor operation.
/// 3. ``DeterministicIntake`` gives the loop somewhere to go when it stops, so
///    stopping is never worse than continuing.
///
/// `IntakeLoop` itself is a value type with no mutable state. All per-run state
/// is either a local variable inside ``run(_:)`` — which no other task can
/// observe — or lives behind the ledger, registry and trace actors. There is no
/// shared mutable field on `self` that could be read on one side of an `await`
/// and written on the other, which is the reentrancy bug this shape exists to
/// make unrepresentable rather than merely absent.
public struct IntakeLoop: Sendable {
    private let model: (any IntakeModel)?
    private let registry: ToolRegistry
    private let validator: RecordValidator
    private let fallback: DeterministicIntake
    private let ladder: ModeLadder
    private let budget: IntakeBudget
    private let traceCapacity: Int
    /// Ceiling on how many invocations from a single `.callTools` turn the loop
    /// will even look at.
    ///
    /// The tool *budget* bounds what gets run; this bounds what gets
    /// **processed**. A model in a degenerate state can name fifty thousand
    /// invocations in one turn, and walking that list to decline 49,996 of them
    /// is the same unbounded-work problem one layer up from where the budget
    /// catches it.
    private let maximumToolRequestsPerTurn: Int

    public init(
        model: (any IntakeModel)?,
        registry: ToolRegistry,
        validator: RecordValidator = RecordValidator(),
        fallback: DeterministicIntake,
        ladder: ModeLadder = .default,
        budget: IntakeBudget = .singlePhoto,
        traceCapacity: Int = 128,
        maximumToolRequestsPerTurn: Int = 8
    ) {
        self.maximumToolRequestsPerTurn = max(1, maximumToolRequestsPerTurn)
        self.model = model
        self.registry = registry
        self.validator = validator
        self.fallback = fallback
        self.ladder = ladder
        self.budget = budget
        self.traceCapacity = max(1, traceCapacity)
    }

    public func run(_ attachment: IntakeAttachment) async -> IntakeResult {
        let ledger = BudgetLedger(budget: budget)
        let trace = IntakeTrace(capacity: traceCapacity)
        let openingSnapshot = await ledger.snapshot
        await trace.record(.runStarted(budget: openingSnapshot))

        var evidence: [ToolResult] = []
        var priorFailures: [ValidationFailure] = []
        var validated: IntakeRecord?
        var cause: TerminationCause

        if let model {
            let outcome = await driveModel(
                model: model,
                attachment: attachment,
                ledger: ledger,
                trace: trace,
                evidence: &evidence,
                priorFailures: &priorFailures
            )
            validated = outcome.record
            cause = outcome.cause
        } else {
            cause = .modelUnavailable("no model configured")
            await trace.record(.modelFailed("no model configured"))
        }

        if let record = validated {
            let snapshot = await ledger.snapshot
            await trace.record(.runFinished(cause: cause, budget: snapshot))
            return IntakeResult(
                record: record,
                provenance: .model,
                termination: cause,
                outstandingFailures: [],
                budget: snapshot,
                trace: await trace.snapshot
            )
        }

        // ---- Fallback ----------------------------------------------------
        await trace.record(.fallbackEngaged(reason: cause))
        if evidence.isEmpty {
            // The model never grounded anything — usually because it was never
            // available. Run the standard tools ourselves, still under the same
            // ledger, so the fallback is a real read rather than a shrug.
            await groundDeterministically(ledger: ledger, trace: trace, evidence: &evidence)
        }

        let fallbackRecord = fallback.record(from: evidence)
        let failures = fallbackRecord.map(validator.validate) ?? []
        let snapshot = await ledger.snapshot
        await trace.record(.runFinished(cause: cause, budget: snapshot))

        return IntakeResult(
            record: fallbackRecord,
            provenance: fallbackRecord == nil ? .none : .deterministicFallback,
            termination: cause,
            outstandingFailures: failures,
            budget: snapshot,
            trace: await trace.snapshot
        )
    }

    // MARK: - Model loop

    /// A provider's own reason, when it gave one, rather than the Swift
    /// description of its error case. The string ends up in a trace a support
    /// engineer reads, so `unavailable("no model on device")` is strictly worse
    /// than `no model on device`.
    private static func describe(_ error: any Error) -> String {
        if let modelError = error as? IntakeModelError,
           case .unavailable(let reason) = modelError {
            return reason
        }
        return String(describing: error)
    }

    /// Evidence is a *set of facts about one photo*, not a log of requests.
    ///
    /// A model that re-asks for OCR it already has gets a coalesced, free
    /// result — and if that result were appended a second time, the fallback
    /// would reconstruct every line item twice and the reconciliation check
    /// would fire against a total that was never wrong. Deduplicating here is
    /// what keeps "repeats are free" from meaning "repeats corrupt the read".
    ///
    /// The scan is linear, over a collection bounded by the tool budget.
    private static func merge(_ result: ToolResult, into evidence: inout [ToolResult]) {
        guard !evidence.contains(where: { $0.invocation == result.invocation }) else { return }
        evidence.append(result)
    }

    private struct ModelOutcome {
        let record: IntakeRecord?
        let cause: TerminationCause
    }

    private func driveModel(
        model: any IntakeModel,
        attachment: IntakeAttachment,
        ledger: BudgetLedger,
        trace: IntakeTrace,
        evidence: inout [ToolResult],
        priorFailures: inout [ValidationFailure]
    ) async -> ModelOutcome {
        var turnIndex = 0
        let availableTools = await registry.registeredNames

        turns: while true {
            guard await ledger.claimTurn() else {
                return ModelOutcome(record: nil, cause: .turnBudgetExhausted)
            }
            let remaining = await ledger.snapshot.toolCallsRemaining
            let mode = ladder.mode(turnIndex: turnIndex, toolCallsRemaining: remaining)
            await trace.record(.turnStarted(index: turnIndex, mode: mode))

            let request = ModelRequest(
                attachment: attachment,
                mode: mode,
                turnIndex: turnIndex,
                toolCallsRemaining: remaining,
                availableTools: availableTools,
                evidence: evidence,
                priorFailures: priorFailures
            )
            guard await ledger.claimContextUnits(model.estimatedContextUnits(for: request)) else {
                return ModelOutcome(record: nil, cause: .contextBudgetExhausted)
            }

            let turn: ModelTurn
            do {
                turn = try await model.respond(to: request)
            } catch {
                let description = Self.describe(error)
                await trace.record(.modelFailed(description))
                return ModelOutcome(record: nil, cause: .modelUnavailable(description))
            }

            switch turn {
            case .callTools(let invocations):
                if mode == .none {
                    let tool = invocations.first?.tool ?? "<unnamed>"
                    let violation = ContractViolation.calledToolWhileModeWasNone(tool: tool)
                    await trace.record(.contractViolated(violation))
                    return ModelOutcome(record: nil, cause: .contractViolation(violation))
                }
                if invocations.isEmpty {
                    await trace.record(.contractViolated(.requestedZeroTools))
                    return ModelOutcome(record: nil, cause: .contractViolation(.requestedZeroTools))
                }
                // Truncate before any per-invocation work, so the cost of this
                // turn is bounded by a constant rather than by the length of a
                // list the model chose.
                let considered = Array(invocations.prefix(maximumToolRequestsPerTurn))
                if considered.count < invocations.count {
                    await trace.record(.toolRequestsTruncated(
                        requested: invocations.count,
                        considered: considered.count
                    ))
                }

                for invocation in considered {
                    let registered = await registry.isRegistered(invocation.tool)
                    guard registered else {
                        let violation = ContractViolation.calledUnregisteredTool(tool: invocation.tool)
                        await trace.record(.contractViolated(violation))
                        return ModelOutcome(record: nil, cause: .contractViolation(violation))
                    }
                }

                // Exhausting the tool budget here is not a failure: the ladder
                // serves `.none` on the next turn and the model emits from what
                // it already has. Only the turn ceiling ends the run.
                await runInvocations(
                    considered,
                    ledger: ledger,
                    trace: trace,
                    evidence: &evidence
                )

            case .emit(let record):
                if mode == .required {
                    await trace.record(.contractViolated(.emittedWhileModeWasRequired))
                    return ModelOutcome(
                        record: nil,
                        cause: .contractViolation(.emittedWhileModeWasRequired)
                    )
                }
                await trace.record(.draftEmitted(record))
                let failures = validator.validate(record)
                if failures.isEmpty {
                    await trace.record(.validationPassed)
                    return ModelOutcome(record: record, cause: .modelEmittedValidRecord)
                }
                await trace.record(.validationFailed(failures))
                priorFailures = failures
                if mode == .none {
                    // The ladder is already at its last rung. Another turn would
                    // ask the same question with the same context and no new
                    // evidence, so the answer would be the same. Stop.
                    return ModelOutcome(record: nil, cause: .validationExhausted(failures))
                }
            }

            turnIndex = Saturating.add(turnIndex, 1)
            if turnIndex == Int.max { break turns }
        }
        return ModelOutcome(record: nil, cause: .turnBudgetExhausted)
    }

    /// Runs as many of the requested invocations as budget allows, recording the
    /// ones it had to decline so the trace explains a short read.
    private func runInvocations(
        _ invocations: [ToolInvocation],
        ledger: BudgetLedger,
        trace: IntakeTrace,
        evidence: inout [ToolResult]
    ) async {
        var billable: [ToolInvocation] = []
        var free: [ToolInvocation] = []
        for invocation in invocations {
            if await registry.cachedPayload(for: invocation) == nil {
                billable.append(invocation)
            } else {
                free.append(invocation)
            }
        }

        // Coalesced repeats are served first and cost nothing.
        for invocation in free {
            await trace.record(.toolRequested(invocation, granted: true))
            if let result = try? await registry.invoke(invocation) {
                Self.merge(result, into: &evidence)
                await trace.record(.toolCompleted(result))
            }
        }

        let granted = await ledger.claimToolCalls(billable.count)
        // `granted` is bounded by `billable.count` by construction in
        // `claimToolCalls`, so both `prefix` and `dropFirst` are in range.
        for invocation in billable.prefix(granted) {
            await trace.record(.toolRequested(invocation, granted: true))
            do {
                let result = try await registry.invoke(invocation)
                Self.merge(result, into: &evidence)
                await trace.record(.toolCompleted(result))
            } catch {
                await trace.record(.toolCompleted(ToolResult(
                    invocation: invocation,
                    payload: .unavailable(reason: String(describing: error))
                )))
            }
        }
        for invocation in billable.dropFirst(granted) {
            await trace.record(.toolRequested(invocation, granted: false))
        }
    }

    /// One pass over the standard tools, used when the model never ran.
    private func groundDeterministically(
        ledger: BudgetLedger,
        trace: IntakeTrace,
        evidence: inout [ToolResult]
    ) async {
        let names = await registry.registeredNames
        // Sorted so the fallback's evidence order is stable across runs —
        // a fallback whose output depends on `Set` iteration order is not
        // deterministic, whatever the type is called.
        for name in names.sorted() {
            let invocation = ToolInvocation(tool: name)
            guard await ledger.claimToolCalls(1) == 1 else { return }
            await trace.record(.toolRequested(invocation, granted: true))
            if let result = try? await registry.invoke(invocation) {
                Self.merge(result, into: &evidence)
                await trace.record(.toolCompleted(result))
            }
        }
    }
}
