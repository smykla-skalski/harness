import Foundation
import XCTest

@testable import HarnessMonitorIntents
@testable import HarnessMonitorKit

extension WebSocketTransport {
  func installTestWebSocketTask(_ task: URLSessionWebSocketTask) {
    webSocketTask = task
  }

  var testWebSocketTask: URLSessionWebSocketTask? {
    webSocketTask
  }
}

final class IntentDaemonClientLifecycleTests: XCTestCase {
  /// `invalidateConnection()` used to drop only the cached task, leaving the
  /// socket open. Every failing pump tick then reconnected and stranded
  /// another ESTABLISHED socket - observed as 10 live sockets to one daemon.
  func testInvalidateConnectionTearsDownTheTransport() async throws {
    let client = makeClient()
    let stranded = URLSession.shared.webSocketTask(
      with: URL(string: "ws://127.0.0.1:1/v1/ws")!
    )
    await client.transport.installTestWebSocketTask(stranded)

    await client.invalidateConnection()

    let remaining = await client.transport.testWebSocketTask
    XCTAssertNil(
      remaining,
      "invalidateConnection must close the socket, not just forget the cached task"
    )
  }

  func testInvalidateConnectionClearsCachedTask() async throws {
    let client = makeClient()

    let task = Task<Void, Error> { /* no-op success */ }
    await client.setConnectionTaskForTesting(task)
    let beforeInvalidate = await client.hasActiveConnectionTaskForTesting
    XCTAssertTrue(beforeInvalidate)

    await client.invalidateConnection()

    let afterInvalidate = await client.hasActiveConnectionTaskForTesting
    XCTAssertFalse(afterInvalidate)
  }

  func testRunRPCPassesThroughIntentDaemonErrorWithoutInvalidating() async throws {
    let client = makeClient()
    let task = Task<Void, Error> { /* no-op success */ }
    await client.setConnectionTaskForTesting(task)

    let validationError = IntentDaemonError.rpcFailed(
      method: "reviews.label",
      message: "Label must not be blank"
    )

    do {
      _ = try await client.runRPC(method: "reviews.label") {
        throw validationError
      }
      XCTFail("expected validation error to propagate")
    } catch let error as IntentDaemonError {
      XCTAssertEqual(error, validationError)
    }

    let stillCached = await client.hasActiveConnectionTaskForTesting
    XCTAssertTrue(
      stillCached,
      "validation errors should not invalidate the cached connection task"
    )
  }

  func testRunRPCInvalidatesOnTransportError() async throws {
    let client = makeClient()
    let task = Task<Void, Error> { /* no-op success */ }
    await client.setConnectionTaskForTesting(task)

    do {
      _ = try await client.runRPC(method: "reviews.query") {
        throw FakeTransportError.disconnected
      }
      XCTFail("expected wrapped failure")
    } catch let error as IntentDaemonError {
      guard case .rpcFailed(let method, let message) = error else {
        XCTFail("expected rpcFailed, got \(error)")
        return
      }
      XCTAssertEqual(method, "reviews.query")
      XCTAssertFalse(message.isEmpty)
    }

    let cleared = await client.hasActiveConnectionTaskForTesting
    XCTAssertFalse(
      cleared,
      "transport errors should clear the cached connection task"
    )
  }

  func testRunRPCReturnsValueOnSuccess() async throws {
    let client = makeClient()
    let task = Task<Void, Error> { /* no-op success */ }
    await client.setConnectionTaskForTesting(task)

    let result: Int = try await client.runRPC(method: "reviews.count") {
      return 42
    }

    XCTAssertEqual(result, 42)
    let stillCached = await client.hasActiveConnectionTaskForTesting
    XCTAssertTrue(stillCached, "successful RPC should leave the connection cached")
  }

  private func makeClient() -> IntentDaemonClient {
    let connection = HarnessMonitorConnection(
      endpoint: URL(string: "ws://127.0.0.1:1/")!,
      token: "test-token"
    )
    return IntentDaemonClient(connection: connection)
  }
}

private enum FakeTransportError: Error, LocalizedError {
  case disconnected

  var errorDescription: String? {
    switch self {
    case .disconnected: "WebSocket connection closed"
    }
  }
}
