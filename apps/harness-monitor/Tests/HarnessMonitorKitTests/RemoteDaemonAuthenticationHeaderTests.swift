import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon authentication headers")
struct RemoteDaemonAuthenticationHeaderTests {
  @Test("HTTP and WebSocket requests bind the remote client id")
  func remoteRequestsIncludeClientID() async throws {
    let connection = HarnessMonitorConnection(
      endpoint: URL(string: "https://daemon.example.com")!,
      token: "opaque-token",
      remoteClientID: "macos-client-1",
      source: .remote(profileID: UUID())
    )
    let client = HarnessMonitorAPIClient(
      connection: connection,
      session: URLSession(configuration: .ephemeral)
    )
    let httpRequest = try client.makeRequest(path: "/v1/sessions")
    var webSocketRequest = URLRequest(url: URL(string: "wss://daemon.example.com/v1/ws")!)
    let webSocket = WebSocketTransport(connection: connection)
    await webSocket.applyHandshakeHeaders(to: &webSocketRequest)

    #expect(
      httpRequest.value(forHTTPHeaderField: "x-harness-remote-client-id")
        == "macos-client-1"
    )
    #expect(
      webSocketRequest.value(forHTTPHeaderField: "x-harness-remote-client-id")
        == "macos-client-1"
    )
    #expect(httpRequest.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token")
    #expect(
      webSocketRequest.value(forHTTPHeaderField: "Authorization") == "Bearer opaque-token"
    )

    await client.shutdown()
    await webSocket.shutdown()
  }

  @Test("Local requests omit the remote client id")
  func localRequestsOmitClientID() throws {
    let connection = HarnessMonitorConnection(
      endpoint: URL(string: "http://127.0.0.1:7777")!,
      token: "local-token",
      remoteClientID: "must-not-leak"
    )
    let client = HarnessMonitorAPIClient(
      connection: connection,
      session: URLSession(configuration: .ephemeral)
    )

    let request = try client.makeRequest(path: "/v1/sessions")

    #expect(request.value(forHTTPHeaderField: "x-harness-remote-client-id") == nil)
  }
}
