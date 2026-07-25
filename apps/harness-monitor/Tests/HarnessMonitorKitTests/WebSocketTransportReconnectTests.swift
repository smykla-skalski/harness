import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketTransport {
  func installTestWebSocketTask(_ task: URLSessionWebSocketTask) {
    webSocketTask = task
  }

  var testWebSocketTask: URLSessionWebSocketTask? {
    webSocketTask
  }
}

@Suite("WebSocket transport reconnect teardown", .serialized)
struct WebSocketTransportReconnectTests {
  private static let deadEndpoint: URL = {
    guard let url = URL(string: "http://127.0.0.1:65535") else {
      preconditionFailure("Invalid test endpoint URL literal")
    }
    return url
  }()

  /// `connect()` assigned over `webSocketTask` without cancelling what was
  /// already there, so a reconnect on a live transport stranded the previous
  /// socket. Nothing ever closed it - `disconnect()` was never reached.
  @Test("connect cancels an existing socket instead of stranding it")
  func connectCancelsPreviousWebSocketTask() async throws {
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(endpoint: Self.deadEndpoint, token: "test")
    )
    let stranded = URLSession.shared.webSocketTask(
      with: URL(string: "ws://127.0.0.1:1/v1/ws")!
    )
    await transport.installTestWebSocketTask(stranded)

    try await transport.connect()

    // A task that was never resumed sits in `.suspended`, so asserting
    // "not running" would pass without any teardown happening. Cancellation
    // is the only state that proves connect() reached the old task.
    #expect(
      stranded.state == .canceling || stranded.state == .completed,
      "the pre-existing task must be cancelled by the new connect, was \(stranded.state)"
    )
    let current = await transport.testWebSocketTask
    #expect(current !== stranded, "connect must install a fresh task")

    await transport.shutdown()
  }
}
