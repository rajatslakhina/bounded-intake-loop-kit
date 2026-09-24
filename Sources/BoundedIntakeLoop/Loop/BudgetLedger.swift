import Foundation

/// The per-run ceiling on everything a model is allowed to spend.
public struct IntakeBudget: Sendable, Equatable {
    /// Maximum grounding tool invocations across the whole run.
    public let toolCalls: Int
    /// Maximum model turns. A belt-and-braces bound: the mode ladder already
    /// guarantees termination, but a bound that does not depend on the model
    /// honouring its contract is the one you actually want in production.
    public let turns: Int
    /// Approximate context ceiling. Counted in the caller's own units — the
    /// ledger only cares that it is a monotonically decreasing integer.
    public let contextUnits: Int

    public init(toolCalls: Int, turns: Int, contextUnits: Int) {
        self.toolCalls = max(0, toolCalls)
        self.turns = max(1, turns)
        self.contextUnits = max(0, contextUnits)
    }

    /// Sized for the shape this pipeline was built for: one grounding pass over a
    /// single photo, one correction pass if validation rejects the first draft.
    public static let singlePhoto = IntakeBudget(toolCalls: 4, turns: 6, contextUnits: 8_000)
}

/// A point-in-time view of spend, safe to carry out of the actor.
public struct BudgetSnapshot: Sendable, Equatable, Codable {
    public let toolCallsUsed: Int
    public let toolCallsLimit: Int
    public let turnsUsed: Int
    public let turnsLimit: Int
    public let contextUnitsUsed: Int
    public let contextUnitsLimit: Int

    public var toolCallsRemaining: Int { max(0, Saturating.subtract(toolCallsLimit, toolCallsUsed)) }
    public var turnsRemaining: Int { max(0, Saturating.subtract(turnsLimit, turnsUsed)) }
    public var contextUnitsRemaining: Int { max(0, Saturating.subtract(contextUnitsLimit, contextUnitsUsed)) }
}

/// Serialises every spend decision for one run.
///
/// The load-bearing property is that each `claim` method's body contains **no
/// `await`**. Actor isolation only protects state across a suspension if no
/// suspension happens between the read and the write; a `claim` written as
/// "read remaining, `await` something, then subtract" would let two turns each
/// observe the same remaining budget and both proceed, which is exactly how a
/// "bounded" loop quietly stops being bounded under concurrency.
///
/// `ConcurrentBudgetClaimTests` asserts this with real concurrent callers rather
/// than by reading the code.
public actor BudgetLedger {
    private let budget: IntakeBudget
    private var toolCallsUsed = 0
    private var turnsUsed = 0
    private var contextUnitsUsed = 0

    public init(budget: IntakeBudget) {
        self.budget = budget
    }

    /// Grants up to `count` tool calls, returning how many were actually
    /// granted — never more than remain, never negative.
    ///
    /// Partial grants matter: a model that asks for three tools when one call
    /// remains should get one call and a truthful `remainingToolCalls: 0` on the
    /// next request, not a hard failure that throws away the work already done.
    public func claimToolCalls(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remaining = max(0, Saturating.subtract(budget.toolCalls, toolCallsUsed))
        let granted = min(count, remaining)
        toolCallsUsed = Saturating.add(toolCallsUsed, granted)
        return granted
    }

    /// Claims a single turn. Returns false once the turn ceiling is reached.
    public func claimTurn() -> Bool {
        guard turnsUsed < budget.turns else { return false }
        turnsUsed = Saturating.add(turnsUsed, 1)
        return true
    }

    /// Records context spend and reports whether the ceiling has been crossed.
    public func claimContextUnits(_ count: Int) -> Bool {
        contextUnitsUsed = Saturating.add(contextUnitsUsed, max(0, count))
        return contextUnitsUsed <= budget.contextUnits
    }

    public var isToolBudgetExhausted: Bool { toolCallsUsed >= budget.toolCalls }
    public var isContextBudgetExhausted: Bool { contextUnitsUsed > budget.contextUnits }

    public var snapshot: BudgetSnapshot {
        BudgetSnapshot(
            toolCallsUsed: toolCallsUsed,
            toolCallsLimit: budget.toolCalls,
            turnsUsed: turnsUsed,
            turnsLimit: budget.turns,
            contextUnitsUsed: contextUnitsUsed,
            contextUnitsLimit: budget.contextUnits
        )
    }
}
