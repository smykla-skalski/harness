import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("PendingRequestStore behavior")
struct PendingRequestStoreTests {
  @Test("PendingRequestStore resume delivers result")
  func pendingStoreResume() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "test-1", continuation: continuation)
      store.resume(id: "test-1", result: .string("hello"))
    }
    #expect(result == .string("hello"))
  }

  @Test("PendingRequestStore fail delivers error")
  func pendingStoreFail() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue =
        try await withCheckedThrowingContinuation { continuation in
          store.register(id: "test-2", continuation: continuation)
          store.fail(
            id: "test-2",
            error: WebSocketTransportError.connectionClosed
          )
        }
    }
  }

  @Test("PendingRequestStore assembles semantic response batches")
  func pendingStoreResumeBatch() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "batched", continuation: continuation)
      _ = try? store.resumeBatch(
        id: "batched",
        index: 1,
        count: 2,
        result: .array([.string("beta")])
      )
      _ = try? store.resumeBatch(
        id: "batched",
        index: 0,
        count: 2,
        result: .array([.string("alpha")])
      )
    }

    #expect(result == .array([.string("alpha"), .string("beta")]))
  }

  @Test("PendingRequestStore failAll clears all pending")
  func pendingStoreFailAll() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue = try await withCheckedThrowingContinuation { continuation in
        store.register(id: "a", continuation: continuation)
        store.failAll(error: WebSocketTransportError.connectionClosed)
      }
    }
  }
}
