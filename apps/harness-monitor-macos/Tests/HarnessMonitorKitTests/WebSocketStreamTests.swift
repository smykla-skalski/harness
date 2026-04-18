import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketTransport {
  func installTestGlobalStreamContinuation(
    _ continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation
  ) {
    globalStreamContinuation = continuation
  }

  func installTestSessionStreamContinuation(
    _ continuation: AsyncThrowingStream<DaemonPushEvent, Error>.Continuation,
    sessionID: String
  ) {
    sessionStreamContinuations[sessionID] = continuation
  }

  func hasTestGlobalStreamContinuation() -> Bool {
    globalStreamContinuation != nil
  }

  func hasTestSessionStreamContinuation(sessionID: String) -> Bool {
    sessionStreamContinuations[sessionID] != nil
  }

  func installTestGlobalSubscriptionActive(_ active: Bool) {
    globalSubscriptionActive = active
  }
}

@Suite("WebSocket stream handling")
struct WebSocketStreamTests {
  private static let testEndpoint: URL = {
    guard let url = URL(string: "http://127.0.0.1:8080") else {
      preconditionFailure("Invalid test endpoint URL literal")
    }
    return url
  }()

  private func makeTransport(
    endpoint: URL = Self.testEndpoint
  ) -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: endpoint,
        token: "test-token"
      )
    )
  }

  @Test("Malformed push frames do not terminate active streams")
  func malformedPushFramesDoNotTerminateActiveStreams() async throws {
    let transport = makeTransport()
    let sessionID = "sess-1"
    let (globalStream, globalContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()
    let (sessionStream, sessionContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()

    await transport.installTestGlobalStreamContinuation(globalContinuation)
    await transport.installTestSessionStreamContinuation(sessionContinuation, sessionID: sessionID)

    let malformedFrame = WsFrame(
      id: nil,
      result: nil,
      error: nil,
      batchIndex: nil,
      batchCount: nil,
      event: "session_updated",
      recordedAt: "2026-04-13T17:30:00Z",
      sessionId: nil,
      payload: .object([:]),
      seq: 1,
      chunkId: nil,
      chunkIndex: nil,
      chunkCount: nil,
      chunkBase64: nil
    )
    try await transport.handleFrame(malformedFrame)

    #expect(await transport.hasTestGlobalStreamContinuation())
    #expect(await transport.hasTestSessionStreamContinuation(sessionID: sessionID))

    let validFrame = WsFrame(
      id: nil,
      result: nil,
      error: nil,
      batchIndex: nil,
      batchCount: nil,
      event: "mystery_event",
      recordedAt: "2026-04-13T17:31:00Z",
      sessionId: sessionID,
      payload: .object(["ok": .bool(true)]),
      seq: 2,
      chunkId: nil,
      chunkIndex: nil,
      chunkCount: nil,
      chunkBase64: nil
    )
    try await transport.handleFrame(validFrame)

    var globalIterator = globalStream.makeAsyncIterator()
    let globalEvent = try await #require(globalIterator.next())
    if case .unknown(let eventName, let payload) = globalEvent.kind {
      #expect(eventName == "mystery_event")
      #expect(payload == .object(["ok": .bool(true)]))
    } else {
      Issue.record("expected unknown global push event after malformed frame")
    }

    var sessionIterator = sessionStream.makeAsyncIterator()
    let sessionEvent = try await #require(sessionIterator.next())
    if case .unknown(let eventName, let payload) = sessionEvent.kind {
      #expect(eventName == "mystery_event")
      #expect(payload == .object(["ok": .bool(true)]))
    } else {
      Issue.record("expected unknown session push event after malformed frame")
    }
  }

  @Test("Reconnect ready events reach active global and session streams")
  func reconnectReadyEventsReachActiveStreams() async throws {
    let transport = makeTransport()
    let sessionID = "sess-reconnect-ready"
    let (globalStream, globalContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()
    let (sessionStream, sessionContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()

    await transport.installTestGlobalStreamContinuation(globalContinuation)
    await transport.installTestSessionStreamContinuation(sessionContinuation, sessionID: sessionID)
    await transport.installTestGlobalSubscriptionActive(true)

    await transport.emitReconnectReadyEvents()

    var globalIterator = globalStream.makeAsyncIterator()
    let globalEvent = try await #require(globalIterator.next())
    if case .ready = globalEvent.kind {
      #expect(globalEvent.sessionId == nil)
    } else {
      Issue.record("expected reconnect-ready global event")
    }

    var sessionIterator = sessionStream.makeAsyncIterator()
    let sessionEvent = try await #require(sessionIterator.next())
    if case .ready = sessionEvent.kind {
      #expect(sessionEvent.sessionId == sessionID)
    } else {
      Issue.record("expected reconnect-ready session event")
    }
  }
}

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
