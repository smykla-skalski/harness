import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketTransport {
  func installTestRPCTimeout(_ timeout: Duration) {
    rpcTimeout = timeout
  }
}

@Suite("WebSocket transport request timeout", .serialized)
struct WebSocketTransportTimeoutTests {
  private static let testEndpoint: URL = {
    guard let url = URL(string: "http://127.0.0.1:65535") else {
      preconditionFailure("Invalid test endpoint URL literal")
    }
    return url
  }()

  @Test("rpc fails with requestTimedOut when underlying sender never returns")
  func rpcFailsWithRequestTimedOutWhenSenderHangs() async throws {
    let waiter = HangingSenderWaiter()
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.testEndpoint, token: "test"),
      session: .shared,
      rpcSender: { _, _, _ in
        try await waiter.waitForever()
      }
    )
    await transport.installTestRPCTimeout(.milliseconds(200))

    let started = ContinuousClock.now
    var capturedError: (any Error)?
    do {
      _ = try await transport.health()
      Issue.record("expected requestTimedOut, got success")
    } catch {
      capturedError = error
    }
    let elapsed = started.duration(to: ContinuousClock.now)

    #expect(capturedError as? WebSocketTransportError == .requestTimedOut)
    #expect(elapsed < .seconds(2))

    waiter.release()
  }

  @Test("rpc returns the sender result when it completes before the timeout")
  func rpcReturnsSenderResultBeforeTimeout() async throws {
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.testEndpoint, token: "test"),
      session: .shared,
      rpcSender: { _, _, _ in
        .object([
          "status": .string("ok"),
          "version": .string("v-test"),
          "pid": .number(42),
          "endpoint": .string("http://127.0.0.1:9999"),
          "started_at": .string("2026-05-22T00:00:00Z"),
          "project_count": .number(0),
          "worktree_count": .number(0),
          "session_count": .number(0),
          "wire_version": .number(1),
        ])
      }
    )
    await transport.installTestRPCTimeout(.seconds(5))

    let health = try await transport.health()
    #expect(health.version == "v-test")
  }

  @Test("requestTimedOut surfaces a human-readable description")
  func requestTimedOutHasUserFacingDescription() {
    let error = WebSocketTransportError.requestTimedOut
    #expect(error.errorDescription?.lowercased().contains("timeout") == true)
  }
}

private final class HangingSenderWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func waitForever() async throws -> JSONValue {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
        return
      }
      continuations.append(continuation)
      lock.unlock()
    }
    return .null
  }

  func release() {
    lock.lock()
    released = true
    let pending = continuations
    continuations.removeAll()
    lock.unlock()
    for continuation in pending {
      continuation.resume()
    }
  }
}
