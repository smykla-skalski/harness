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

  @Test("ACP event pushes coalesce overflow batches and log once per burst")
  func acpEventPushesCoalesceOverflowBatchesAndLogOncePerBurst() async throws {
    let transport = makeTransport()
    let sessionID = "sess-acp-burst"
    let (sessionStream, sessionContinuation) = AsyncThrowingStream<DaemonPushEvent, Error>
      .makeStream()

    await transport.installTestSessionStreamContinuation(sessionContinuation, sessionID: sessionID)
    await transport.setAcpEventAutoFlushEnabledForTests(false)

    for sequence in 0..<1_024 {
      await transport.enqueueAcpEventPush(
        recordedAt: isoTimestamp(sequence),
        sessionId: sessionID,
        payload: makeAcpEventBatchPayloadJSON(
          acpID: "acp-1",
          sessionID: sessionID,
          rawCount: 1,
          events: [
            makeAcpConversationEvent(
              recordedAt: isoTimestamp(sequence),
              sequence: UInt64(sequence)
            )
          ]
        )
      )
    }

    await transport.flushPendingAcpEventPushes()

    var iterator = sessionStream.makeAsyncIterator()
    let push = try await #require(iterator.next())

    if case .acpEvents(let batch) = push.kind {
      #expect(batch.rawCount == 1_024)
      #expect(batch.events.count == 256)
      #expect(batch.events.first?.sequence == 768)
      #expect(batch.events.last?.sequence == 1_023)
      #expect(push.recordedAt == isoTimestamp(1_023))
    } else {
      Issue.record("expected coalesced ACP event batch push")
    }

    #expect(await transport.acpOverflowLogBurstCountForTests() == 1)
  }

  @Test("ACP overflow logging stays at one burst across multiple ACP queues")
  func acpOverflowLoggingStaysAtOneBurstAcrossMultipleAcpQueues() async {
    let transport = makeTransport()
    let sessionID = "sess-acp-multi-burst"

    await transport.setAcpEventAutoFlushEnabledForTests(false)

    for acpID in ["acp-1", "acp-2"] {
      for sequence in 0..<512 {
        await transport.enqueueAcpEventPush(
          recordedAt: isoTimestamp(sequence),
          sessionId: sessionID,
          payload: makeAcpEventBatchPayloadJSON(
            acpID: acpID,
            sessionID: sessionID,
            rawCount: 1,
            events: [
              makeAcpConversationEvent(
                recordedAt: isoTimestamp(sequence),
                sequence: UInt64(sequence)
              )
            ]
          )
        )
      }
    }

    await transport.flushPendingAcpEventPushes()

    #expect(await transport.acpOverflowLogBurstCountForTests() == 1)
  }

  private func makeAcpEventBatchPayloadJSON(
    acpID: String,
    sessionID: String,
    rawCount: Int,
    events: [AcpConversationEvent]
  ) -> JSONValue {
    .object([
      "acpId": .string(acpID),
      "sessionId": .string(sessionID),
      "rawCount": .number(Double(rawCount)),
      "events": .array(
        events.map { event in
          .object([
            "timestamp": event.timestamp.map(JSONValue.string) ?? .null,
            "sequence": .number(Double(event.sequence)),
            "kind": event.kind,
            "agent": .string(event.agent),
            "sessionId": .string(event.sessionId),
          ])
        }
      ),
    ])
  }

  private func makeAcpConversationEvent(
    recordedAt: String,
    sequence: UInt64
  ) -> AcpConversationEvent {
    AcpConversationEvent(
      timestamp: recordedAt,
      sequence: sequence,
      kind: .object([
        "type": .string("tool_invocation"),
        "tool_name": .string("Read"),
        "invocation_id": .string("call-\(sequence)"),
      ]),
      agent: "copilot",
      sessionId: "sess-acp-burst"
    )
  }

  private func isoTimestamp(_ secondOffset: Int) -> String {
    String(format: "2026-04-28T00:00:%02dZ", secondOffset % 60)
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
