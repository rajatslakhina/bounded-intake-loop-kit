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
        XCTAssertEqual(first.payload, third.payload)
    }

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
