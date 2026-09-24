import Foundation

/// One observable thing the loop did.
///
/// The trace is the only reason a failure in this pipeline is debuggable at all.
/// A user reports "it read the wrong total off my receipt"; without the trace the
/// answer is a shrug, and with it the answer is "turn 2 re-requested OCR, got a
/// coalesced result, and the model still emitted the same total — the OCR line
/// is wrong, not the model."
public enum TraceEvent: Sendable, Equatable, Codable {
    case runStarted(budget: BudgetSnapshot)
    case turnStarted(index: Int, mode: ToolCallingMode)
    case toolRequested(ToolInvocation, granted: Bool)
    case toolCompleted(ToolResult)
    case draftEmitted(IntakeRecord)
    case validationFailed([ValidationFailure])
    case validationPassed
    case contractViolated(ContractViolation)
    case modelFailed(String)
    case fallbackEngaged(reason: TerminationCause)
    case runFinished(cause: TerminationCause, budget: BudgetSnapshot)
    /// Emitted exactly once, in place of the events that were dropped, when the
    /// ring buffer wraps. A trace that silently loses its middle is worse than
    /// one that says it did.
    case eventsDropped(count: Int)
}

/// A bounded, ordered trace.
///
/// Capacity is fixed at init. This is the difference between a trace and a leak:
/// the number of events is driven by model behaviour, so an unbounded array here
/// is unbounded memory growth with an external party holding the dial. When the
/// buffer wraps, the oldest events are dropped and the drop is reported, so the
/// reader always knows the trace is partial.
public actor IntakeTrace {
    private var events: [TraceEvent] = []
    private var droppedCount = 0
    private let capacity: Int

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
        events.reserveCapacity(self.capacity)
    }

    public func record(_ event: TraceEvent) {
        if events.count >= capacity {
            // `capacity >= 1` and `events.count >= capacity` together guarantee
            // the buffer is non-empty, so `removeFirst()` is in bounds.
            events.removeFirst()
            droppedCount = Saturating.add(droppedCount, 1)
        }
        events.append(event)
    }

    /// The trace as a flat array, with a single dropped-events marker at the
    /// front when anything was lost.
    public var snapshot: [TraceEvent] {
        guard droppedCount > 0 else { return events }
        return [.eventsDropped(count: droppedCount)] + events
    }

    public var storedEventCount: Int { events.count }
    public var droppedEventCount: Int { droppedCount }
}
