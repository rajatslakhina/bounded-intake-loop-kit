import Foundation

/// A request from the model for grounded evidence.
public struct ToolInvocation: Sendable, Equatable, Hashable, Codable {
    public let tool: String
    /// Opaque to the loop; interpreted by the tool. Kept as a string so an
    /// invocation is `Hashable` and therefore coalescable.
    public let argument: String

    public init(tool: String, argument: String = "") {
        self.tool = tool
        self.argument = argument
    }
}

/// Evidence returned by a tool.
///
/// A closed enum rather than a free-form string: the deterministic fallback path
/// has to reconstruct a record from tool output *without* a model, which is only
/// possible if the output has a shape the code can read.
public enum ToolPayload: Sendable, Equatable, Codable {
    case recognizedText([String])
    case barcode(String)
    case keyValues([String: String])
    case unavailable(reason: String)

    public var isUsableEvidence: Bool {
        switch self {
        case .unavailable: return false
        case .recognizedText(let lines): return !lines.isEmpty
        case .barcode(let value): return !value.isEmpty
        case .keyValues(let pairs): return !pairs.isEmpty
        }
    }
}

public struct ToolResult: Sendable, Equatable, Codable {
    public let invocation: ToolInvocation
    public let payload: ToolPayload
    /// True when this result was served from the run's coalescing cache rather
    /// than by invoking the tool again.
    public let wasCoalesced: Bool

    public init(invocation: ToolInvocation, payload: ToolPayload, wasCoalesced: Bool = false) {
        self.invocation = invocation
        self.payload = payload
        self.wasCoalesced = wasCoalesced
    }
}

/// Anything that can turn an invocation into evidence.
///
/// On device the conforming types wrap the platform's OCR and barcode tools; in
/// tests and in the demo app they are scripted. The loop does not know or care,
/// which is the entire point of the seam: the termination and budget arguments
/// are properties of the loop, not of whichever vendor is behind this protocol
/// this quarter.
public protocol GroundingTool: Sendable {
    var name: String { get }
    func invoke(_ invocation: ToolInvocation) async throws -> ToolPayload
}

/// Names the loop and the fallback both understand.
public enum StandardTool {
    public static let recognizeText = "recognizeText"
    public static let readBarcode = "readBarcode"
}

/// Dispatch plus per-run request coalescing.
///
/// A model that has just been told its record failed validation will very often
/// re-request the identical tool call it already made. Serving that from a cache
/// rather than re-running OCR is not an optimisation — under a budget of four
/// calls, a duplicate is a call the model does not get to spend on something new.
///
/// The cache is scoped to one run and capped, so it cannot become a leak that
/// grows with model chattiness.
public actor ToolRegistry {
    private let tools: [String: any GroundingTool]
    private var cache: [ToolInvocation: ToolPayload] = [:]
    private var cacheOrder: [ToolInvocation] = []
    /// Invocations currently running. Without this, two concurrent callers both
    /// miss the cache, both suspend into the tool, and "coalescing" turns out to
    /// be a property of calling serially rather than a property of the registry.
    private var inFlight: [ToolInvocation: Task<ToolPayload, Never>] = [:]
    private let cacheLimit: Int

    public init(tools: [any GroundingTool], cacheLimit: Int = 32) {
        var table: [String: any GroundingTool] = [:]
        for tool in tools {
            table[tool.name] = tool
        }
        self.tools = table
        self.cacheLimit = max(1, cacheLimit)
    }

    public func isRegistered(_ name: String) -> Bool {
        tools[name] != nil
    }

    public var registeredNames: Set<String> {
        Set(tools.keys)
    }

    /// Peeks at the coalescing cache without running anything.
    ///
    /// The loop uses this to decide whether an invocation should cost budget at
    /// all. A duplicate request is free, which matters a great deal when the
    /// ceiling is four calls and a model that has just been told its draft was
    /// rejected reflexively re-requests the OCR it already has.
    public func cachedPayload(for invocation: ToolInvocation) -> ToolPayload? {
        cache[invocation]
    }

    /// Runs the invocation, or returns the coalesced result.
    ///
    /// Throws ``ToolRegistryError/unregistered`` rather than returning an
    /// `.unavailable` payload, because an unregistered tool is a contract
    /// violation by the model and the loop terminates on it, whereas a tool that
    /// ran and found nothing is ordinary evidence.
    /// Everything from the cache read down to installing the in-flight task runs
    /// with **no `await`**, so a second caller either sees the cached payload or
    /// sees the task the first caller installed. There is no window in which two
    /// callers both decide to run the tool. (`Task { }` is not a suspension
    /// point; the first `await` is on `task.value`, after the map is written.)
    public func invoke(_ invocation: ToolInvocation) async throws -> ToolResult {
        if let cached = cache[invocation] {
            return ToolResult(invocation: invocation, payload: cached, wasCoalesced: true)
        }
        guard let tool = tools[invocation.tool] else {
            throw ToolRegistryError.unregistered(invocation.tool)
        }
        if let running = inFlight[invocation] {
            let payload = await Self.value(of: running)
            return ToolResult(invocation: invocation, payload: payload, wasCoalesced: true)
        }
        let task = Task<ToolPayload, Never> {
            do {
                return try await tool.invoke(invocation)
            } catch {
                // A failing tool is evidence of absence, not a crash: the
                // fallback path still has whatever the other tools produced.
                return .unavailable(reason: String(describing: error))
            }
        }
        inFlight[invocation] = task

        let payload = await Self.value(of: task)

        inFlight[invocation] = nil
        store(payload, for: invocation)
        return ToolResult(invocation: invocation, payload: payload, wasCoalesced: false)
    }

    /// Waits for the shared task, forwarding the waiter's cancellation to it.
    ///
    /// An unstructured `Task` does **not** inherit cancellation from whoever
    /// created it, so without this a cancelled intake run would leave the tool
    /// running with nobody listening. `withTaskCancellationHandler` closes that:
    /// cancelling the caller cancels the shared task, which a cooperative tool
    /// honours. A tool that ignores `Task.isCancelled` still cannot be stopped —
    /// that is a requirement on conformers, documented rather than pretended
    /// away, because Swift offers no way to abandon an in-progress `await`.
    private static func value(of task: Task<ToolPayload, Never>) async -> ToolPayload {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Insertion-ordered eviction. `cacheOrder` and `cache` are mutated together
    /// with no `await` between them, so they cannot diverge under reentrancy.
    private func store(_ payload: ToolPayload, for invocation: ToolInvocation) {
        if cache[invocation] == nil {
            if cacheOrder.count >= cacheLimit, !cacheOrder.isEmpty {
                let evicted = cacheOrder.removeFirst()
                cache[evicted] = nil
            }
            cacheOrder.append(invocation)
        }
        cache[invocation] = payload
    }

    public var cachedInvocationCount: Int { cacheOrder.count }
}

public enum ToolRegistryError: Error, Equatable {
    case unregistered(String)
}
