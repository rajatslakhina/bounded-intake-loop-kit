import Foundation

/// One pinned behaviour of the loop.
///
/// The reason this exists as a shipped type rather than as XCTest cases: the
/// behaviour that has to stay stable is not "the code compiles", it is "this
/// photo still produces this record on the next OS version, with the same
/// provenance and inside the same budget". That is a claim about a model you do
/// not own, so it has to be re-checkable on a device, in the app, after an
/// update — not only on CI.
public struct IntakeEvalCase: Sendable {
    public let name: String
    public let loop: IntakeLoop
    public let attachment: IntakeAttachment
    public let expectedProvenance: Provenance
    /// `nil` means "any record is acceptable"; `.some(nil)` means "expect no
    /// record at all".
    public let expectedRecord: IntakeRecord??
    public let maximumToolCalls: Int
    public let requiresCleanValidation: Bool

    public init(
        name: String,
        loop: IntakeLoop,
        attachment: IntakeAttachment,
        expectedProvenance: Provenance,
        expectedRecord: IntakeRecord?? = nil,
        maximumToolCalls: Int,
        requiresCleanValidation: Bool = true
    ) {
        self.name = name
        self.loop = loop
        self.attachment = attachment
        self.expectedProvenance = expectedProvenance
        self.expectedRecord = expectedRecord
        self.maximumToolCalls = maximumToolCalls
        self.requiresCleanValidation = requiresCleanValidation
    }
}

public struct IntakeEvalOutcome: Sendable, Equatable {
    public let name: String
    public let failures: [String]
    public let provenance: Provenance
    public let toolCallsUsed: Int
    public let turnsUsed: Int
    public var passed: Bool { failures.isEmpty }
}

public struct IntakeEvalReport: Sendable, Equatable {
    public let outcomes: [IntakeEvalOutcome]
    public var passed: Bool { outcomes.allSatisfy(\.passed) }
    public var passedCount: Int { outcomes.filter(\.passed).count }
    public var totalCount: Int { outcomes.count }
}

public struct IntakeEvalHarness: Sendable {
    public init() {}

    public func run(_ cases: [IntakeEvalCase]) async -> IntakeEvalReport {
        var outcomes: [IntakeEvalOutcome] = []
        outcomes.reserveCapacity(cases.count)
        for evalCase in cases {
            outcomes.append(await run(evalCase))
        }
        return IntakeEvalReport(outcomes: outcomes)
    }

    public func run(_ evalCase: IntakeEvalCase) async -> IntakeEvalOutcome {
        let result = await evalCase.loop.run(evalCase.attachment)
        var failures: [String] = []

        if result.provenance != evalCase.expectedProvenance {
            failures.append(
                "provenance was \(result.provenance.rawValue), expected \(evalCase.expectedProvenance.rawValue)"
            )
        }
        if let expected = evalCase.expectedRecord, expected != result.record {
            failures.append("record did not match the pinned value")
        }
        if result.budget.toolCallsUsed > evalCase.maximumToolCalls {
            failures.append(
                "used \(result.budget.toolCallsUsed) tool calls, budgeted \(evalCase.maximumToolCalls)"
            )
        }
        // The ceiling is a property of the loop, not of the eval: a run that
        // exceeded it means the bound itself broke, which is worth its own line.
        if result.budget.toolCallsUsed > result.budget.toolCallsLimit {
            failures.append("BOUND VIOLATED: tool calls exceeded the ledger limit")
        }
        if result.budget.turnsUsed > result.budget.turnsLimit {
            failures.append("BOUND VIOLATED: turns exceeded the ledger limit")
        }
        if evalCase.requiresCleanValidation && !result.outstandingFailures.isEmpty {
            failures.append("record carried \(result.outstandingFailures.count) outstanding failure(s)")
        }

        return IntakeEvalOutcome(
            name: evalCase.name,
            failures: failures,
            provenance: result.provenance,
            toolCallsUsed: result.budget.toolCallsUsed,
            turnsUsed: result.budget.turnsUsed
        )
    }
}
