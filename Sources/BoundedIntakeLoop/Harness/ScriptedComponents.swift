import Foundation

/// A grounding tool that always returns the same payload.
///
/// Shipped in the library rather than hidden in the test target on purpose: the
/// demo app, the eval suite and the unit tests all need a model-free way to
/// exercise the loop, and a seam you can only fill on a device is a seam you
/// cannot test in CI.
public struct StaticGroundingTool: GroundingTool {
    public let name: String
    private let payload: ToolPayload
    private let failure: (any Error)?

    public init(name: String, payload: ToolPayload) {
        self.name = name
        self.payload = payload
        self.failure = nil
    }

    /// A tool that throws. Used to prove that a failing tool degrades the read
    /// rather than the process.
    public init(name: String, failingWith error: any Error) {
        self.name = name
        self.payload = .unavailable(reason: String(describing: error))
        self.failure = error
    }

    public func invoke(_ invocation: ToolInvocation) async throws -> ToolPayload {
        if let failure { throw failure }
        return payload
    }
}

/// Counts invocations, so tests can assert that coalescing actually coalesced
/// instead of asserting on a cache-hit counter the cache itself reports.
public actor CountingGroundingTool: GroundingTool {
    public nonisolated let name: String
    private let payload: ToolPayload
    private var count = 0

    public init(name: String, payload: ToolPayload) {
        self.name = name
        self.payload = payload
    }

    public func invoke(_ invocation: ToolInvocation) async throws -> ToolPayload {
        count += 1
        return payload
    }

    public var invocationCount: Int { count }
}

/// A model that is never available.
public struct UnavailableIntakeModel: IntakeModel {
    public let reason: String

    public init(reason: String = "model not available on this device") {
        self.reason = reason
    }

    public func respond(to request: ModelRequest) async throws -> ModelTurn {
        throw IntakeModelError.unavailable(reason)
    }
}

/// Replays a fixed script of turns.
///
/// This is how every "what if the provider misbehaves" scenario is expressed:
/// a script of `.callTools` with ``Exhaustion/repeatLast`` is a model that never
/// stops asking, and the loop's bound is what has to hold.
public actor ScriptedIntakeModel: IntakeModel {
    public enum Exhaustion: Sendable {
        /// Keep returning the final scripted turn forever.
        case repeatLast
        /// Throw once the script runs out.
        case fail
        /// Emit this record once the script runs out.
        case emit(IntakeRecord)
    }

    private let script: [ModelTurn]
    private let exhaustion: Exhaustion
    private var index = 0
    private var observedModes: [ToolCallingMode] = []

    public init(script: [ModelTurn], whenExhausted exhaustion: Exhaustion = .fail) {
        self.script = script
        self.exhaustion = exhaustion
    }

    public func respond(to request: ModelRequest) async throws -> ModelTurn {
        observedModes.append(request.mode)
        if index < script.count {
            let turn = script[index]
            index += 1
            return turn
        }
        switch exhaustion {
        case .repeatLast:
            guard let last = script.last else {
                throw IntakeModelError.unavailable("empty script")
            }
            return last
        case .fail:
            throw IntakeModelError.unavailable("script exhausted")
        case .emit(let record):
            return .emit(record)
        }
    }

    /// Every mode the loop served, in order. The ladder's behaviour is asserted
    /// against this rather than against the loop's own trace, so a bug in the
    /// trace cannot make a ladder test pass.
    public var modesServed: [ToolCallingMode] { observedModes }
    public var turnsServed: Int { observedModes.count }
}
