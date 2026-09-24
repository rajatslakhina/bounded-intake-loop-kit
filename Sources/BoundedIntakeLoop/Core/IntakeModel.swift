import Foundation

/// The image being read. Opaque bytes plus a hint, so the package has no
/// dependency on any imaging framework and the loop stays testable.
public struct IntakeAttachment: Sendable, Equatable {
    public let identifier: String
    public let data: Data
    public let hint: String?

    public init(identifier: String, data: Data = Data(), hint: String? = nil) {
        self.identifier = identifier
        self.data = data
        self.hint = hint
    }
}

/// Everything the model is told on a turn.
///
/// `mode` and `toolCallsRemaining` are both present deliberately. The mode is
/// the instruction; the remaining count is the reason. Providers that surface
/// the count to the model produce noticeably fewer wasted requests than
/// providers that only clamp the mode, and a request struct that carries only
/// the mode cannot express that.
public struct ModelRequest: Sendable {
    public let attachment: IntakeAttachment
    public let mode: ToolCallingMode
    public let turnIndex: Int
    public let toolCallsRemaining: Int
    public let availableTools: Set<String>
    public let evidence: [ToolResult]
    /// Non-nil when the previous draft was rejected — the model is being asked
    /// to correct a specific thing, not to try again.
    public let priorFailures: [ValidationFailure]

    public init(
        attachment: IntakeAttachment,
        mode: ToolCallingMode,
        turnIndex: Int,
        toolCallsRemaining: Int,
        availableTools: Set<String>,
        evidence: [ToolResult],
        priorFailures: [ValidationFailure]
    ) {
        self.attachment = attachment
        self.mode = mode
        self.turnIndex = turnIndex
        self.toolCallsRemaining = toolCallsRemaining
        self.availableTools = availableTools
        self.evidence = evidence
        self.priorFailures = priorFailures
    }
}

/// What the model did with a turn.
public enum ModelTurn: Sendable, Equatable {
    case callTools([ToolInvocation])
    case emit(IntakeRecord)
}

/// The seam.
///
/// One method, because the loop's contract with a provider is genuinely one
/// method wide. An on-device adapter, a hosted adapter and a scripted test
/// double are all a conformance away, and none of them can change the loop's
/// termination, budget or validation behaviour — which is the property worth
/// having when the provider landscape moves every quarter.
public protocol IntakeModel: Sendable {
    /// Rough context cost of this request, in the same units as
    /// ``IntakeBudget/contextUnits``. Defaulted so a test double need not care.
    func estimatedContextUnits(for request: ModelRequest) -> Int
    func respond(to request: ModelRequest) async throws -> ModelTurn
}

public extension IntakeModel {
    func estimatedContextUnits(for request: ModelRequest) -> Int {
        // Deliberately crude: the point of the ceiling is to exist, not to be
        // accurate. A precise estimate that is only available from the provider
        // would put the ceiling back under the provider's control.
        let evidenceCost = request.evidence.reduce(0) { total, result in
            switch result.payload {
            case .recognizedText(let lines):
                return Saturating.add(total, Saturating.multiply(lines.count, 16))
            case .keyValues(let pairs):
                return Saturating.add(total, Saturating.multiply(pairs.count, 16))
            case .barcode, .unavailable:
                return Saturating.add(total, 8)
            }
        }
        return Saturating.add(512, evidenceCost)
    }
}

public enum IntakeModelError: Error, Equatable {
    case unavailable(String)
}
