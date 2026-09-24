import XCTest
@testable import BoundedIntakeLoop

final class ToolRegistryTests: XCTestCase {

    /// Asserts coalescing by counting invocations on the tool itself, not by
    /// reading a hit counter the cache maintains. A cache that reports a hit
    /// while still calling through would pass the second kind of test.
    func testIdenticalInvocationsRunTheToolExactlyOnce() async throws {
        let tool = CountingGroundingTool(
            name: StandardTool.recognizeText,
            payload: .recognizedText(["A 1.00"])
        )
        let registry = ToolRegistry(tools: [tool])
        let invocation = ToolInvocation(tool: StandardTool.recognizeText)

        let first = try await registry.invoke(invocation)
        let second = try await registry.invoke(invocation)
        let third = try await registry.invoke(invocation)

        let count = await tool.invocationCount
        XCTAssertEqual(count, 1)
        XCTAssertFalse(first.wasCoalesced)
        XCTAssertTrue(second.wasCoalesced)
        XCTAssertTrue(third.wasCoalesced)
        // Compared against the payload the tool was configured with, not against
        // the first result — a cache that returned garbage consistently would
        // pass a self-comparison.
        XCTAssertEqual(third.payload, .recognizedText(["A 1.00"]))
    }

    /// Coalescing under genuine concurrency.
    ///
    /// 64 tasks race on the same invocation against a tool that suspends before
    /// answering. A registry that reads the cache, `await`s the tool, and only
    /// then writes lets every one of them through: all 64 miss, all 64 suspend,
    /// all 64 call the tool. Sequential tests cannot see that, so this one runs
    /// them together and asserts the tool was entered exactly once.
    func testConcurrentIdenticalInvocationsStillRunTheToolOnce() async {
        let tool = SlowCountingTool(payload: .barcode("96385074"))
        let registry = ToolRegistry(tools: [tool])
        let invocation = ToolInvocation(tool: tool.name)

        let coalesced = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<64 {
                group.addTask {
                    (try? await registry.invoke(invocation))?.wasCoalesced ?? false
                }
            }
            var count = 0
            for await wasCoalesced in group where wasCoalesced { count += 1 }
            return count
        }

        let entries = await tool.entryCount
        XCTAssertEqual(entries, 1, "the tool must be entered exactly once for 64 identical callers")
        XCTAssertEqual(coalesced, 63, "every caller but the first is served the shared result")
    }
}

extension ToolRegistryTests {

    func testDifferentArgumentsAreNotCoalesced() async throws {
        let tool = CountingGroundingTool(
            name: StandardTool.recognizeText,
            payload: .recognizedText(["A 1.00"])
        )
        let registry = ToolRegistry(tools: [tool])
        _ = try await registry.invoke(ToolInvocation(tool: StandardTool.recognizeText, argument: "top"))
        _ = try await registry.invoke(ToolInvocation(tool: StandardTool.recognizeText, argument: "bottom"))
        let count = await tool.invocationCount
        XCTAssertEqual(count, 2)
    }

    func testCacheIsBoundedAndEvictsInInsertionOrder() async throws {
        let tool = StaticGroundingTool(name: "t", payload: .barcode("96385074"))
        let registry = ToolRegistry(tools: [tool], cacheLimit: 4)
        for index in 0..<50 {
            _ = try await registry.invoke(ToolInvocation(tool: "t", argument: "\(index)"))
        }
        let cached = await registry.cachedInvocationCount
        XCTAssertEqual(cached, 4)
        let oldest = await registry.cachedPayload(for: ToolInvocation(tool: "t", argument: "0"))
        let newest = await registry.cachedPayload(for: ToolInvocation(tool: "t", argument: "49"))
        XCTAssertNil(oldest)
        XCTAssertNotNil(newest)
    }

    func testUnregisteredToolThrowsRatherThanReturningEmptyEvidence() async {
        let registry = ToolRegistry(tools: [StaticGroundingTool(name: "t", payload: .barcode("96385074"))])
        do {
            _ = try await registry.invoke(ToolInvocation(tool: "nope"))
            XCTFail("an unregistered tool must not be silently tolerated")
        } catch {
            XCTAssertEqual(error as? ToolRegistryError, .unregistered("nope"))
        }
    }

    func testAFailingToolDegradesToUnavailableEvidence() async throws {
        struct Boom: Error {}
        let registry = ToolRegistry(tools: [StaticGroundingTool(name: "t", failingWith: Boom())])
        let result = try await registry.invoke(ToolInvocation(tool: "t"))
        guard case .unavailable = result.payload else {
            return XCTFail("a throwing tool should produce unavailable evidence, not propagate")
        }
        XCTAssertFalse(result.payload.isUsableEvidence)
    }
}

/// A tool that suspends between being entered and answering, so a race window
/// genuinely exists for `testConcurrentIdenticalInvocationsStillRunTheToolOnce`
/// to close. `StaticGroundingTool` returns immediately and would let a broken
/// registry pass by accident.
private actor SlowCountingTool: GroundingTool {
    nonisolated let name = StandardTool.readBarcode
    private let payload: ToolPayload
    private(set) var entryCount = 0

    init(payload: ToolPayload) {
        self.payload = payload
    }

    func invoke(_ invocation: ToolInvocation) async throws -> ToolPayload {
        entryCount += 1
        try? await Task.sleep(nanoseconds: 20_000_000)
        return payload
    }
}
