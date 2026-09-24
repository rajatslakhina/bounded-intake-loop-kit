import Foundation

/// Mirrors the per-request tool-calling control an on-device model exposes.
///
/// Declared here rather than imported so the loop, its tests and the whole
/// termination argument compile and run on a Linux CI box with no model
/// framework present. An adapter maps these three cases onto the platform type.
public enum ToolCallingMode: Sendable, Hashable, Codable, CaseIterable {
    /// The model must call a tool this turn. Used for the first turn so the
    /// first thing in the transcript is evidence rather than a guess.
    case required
    /// The model may call a tool or emit.
    case allowed
    /// The model must emit. This is the rung that makes the loop terminate.
    case none
}

/// Why the loop stopped asking the model.
public enum TerminationCause: Sendable, Equatable, Codable {
    /// The model emitted a record that passed every invariant.
    case modelEmittedValidRecord
    /// The model emitted, repeatedly, records that failed validation.
    case validationExhausted([ValidationFailure])
    /// The grounding tool budget ran out.
    case toolBudgetExhausted
    /// The turn ceiling was reached.
    case turnBudgetExhausted
    /// The context ceiling was crossed.
    case contextBudgetExhausted
    /// The model called a tool while the mode was `.none`, or requested a tool
    /// that is not registered. Both mean the provider is not honouring the
    /// contract, and neither is worth retrying.
    case contractViolation(ContractViolation)
    /// The model was unavailable, errored, or was never configured.
    case modelUnavailable(String)
}

public enum ContractViolation: Sendable, Equatable, Codable {
    case calledToolWhileModeWasNone(tool: String)
    case calledUnregisteredTool(tool: String)
    case emittedWhileModeWasRequired
    case requestedZeroTools
}

/// The mode ladder: the rule that turns "an agent loop" into "a loop that
/// provably stops".
///
/// The ladder only ever descends — `required` → `allowed` → `none` — and it
/// descends on a counter the model cannot influence. This is the whole
/// termination argument, and it is deliberately not a heuristic about whether
/// the model "seems done": a model that seems done is a model that has not yet
/// had a bad day.
public struct ModeLadder: Sendable, Equatable {
    /// Turns spent in `.required` before descending to `.allowed`.
    public let requiredTurns: Int
    /// Additional turns spent in `.allowed` before descending to `.none`.
    public let allowedTurns: Int

    public init(requiredTurns: Int = 1, allowedTurns: Int = 2) {
        self.requiredTurns = max(0, requiredTurns)
        self.allowedTurns = max(0, allowedTurns)
    }

    public static let `default` = ModeLadder()

    /// The mode for a zero-based turn index, given how much tool budget is left.
    ///
    /// Two independent descents, and either alone is sufficient for termination:
    ///
    /// 1. **Turn index.** Once `turnIndex >= requiredTurns + allowedTurns` the
    ///    mode is `.none` forever after. Since the loop increments `turnIndex`
    ///    every iteration, the ladder reaches `.none` in a bounded number of
    ///    turns regardless of what the model does.
    /// 2. **Tool budget.** With no tool calls left, `.required` would ask the
    ///    model to do something impossible and `.allowed` would invite it to,
    ///    so both collapse to `.none` immediately.
    public func mode(turnIndex: Int, toolCallsRemaining: Int) -> ToolCallingMode {
        guard toolCallsRemaining > 0 else { return .none }
        guard turnIndex >= 0 else { return .required }
        if turnIndex < requiredTurns { return .required }
        let allowedCeiling = Saturating.add(requiredTurns, allowedTurns)
        if turnIndex < allowedCeiling { return .allowed }
        return .none
    }

    /// The turn index at which the ladder is guaranteed to be at `.none`,
    /// independent of tool budget. Used by ``IntakeLoop`` to bound its own turn
    /// ceiling and asserted directly in `ModeLadderTests`.
    public var terminalTurnIndex: Int {
        Saturating.add(requiredTurns, allowedTurns)
    }
}
