import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Dashboard ACP HTTP client")
struct DashboardAcpHTTPClientTests {
  @Test("Provider-session controls use managed-agent HTTP routes")
  func providerSessionControlsUseManagedAgentRoutes() async throws {
    DashboardAcpURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DashboardAcpURLProtocol.self]
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: URLSession(configuration: configuration)
    )

    let page = try await client.managedAcpSessions(
      agentID: "acp-dashboard",
      cwd: "/tmp/project with space",
      cursor: "opaque-cursor"
    )
    try await client.closeManagedAcpSession(
      agentID: "acp-dashboard",
      sessionID: "provider-session"
    )
    try await client.deleteManagedAcpSession(
      agentID: "acp-dashboard",
      sessionID: "provider-session"
    )
    try await client.logoutManagedAcpAgent(agentID: "acp-dashboard")

    #expect(page.sessions.map(\.sessionID) == ["provider-session"])
    let requests = DashboardAcpURLProtocol.requests
    #expect(requests.map(\.method) == ["GET", "POST", "DELETE", "POST"])
    #expect(
      requests.map(\.url.path) == [
        "/v1/managed-agents/acp-dashboard/sessions",
        "/v1/managed-agents/acp-dashboard/sessions/provider-session/close",
        "/v1/managed-agents/acp-dashboard/sessions/provider-session",
        "/v1/managed-agents/acp-dashboard/logout",
      ]
    )
    let query = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
    #expect(query?.contains(URLQueryItem(name: "cwd", value: "/tmp/project with space")) == true)
    #expect(query?.contains(URLQueryItem(name: "cursor", value: "opaque-cursor")) == true)
  }
}

private final class DashboardAcpURLProtocol: URLProtocol, @unchecked Sendable {
  struct Request: Sendable {
    let method: String
    let url: URL
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestStorage: [Request] = []

  static var requests: [Request] { lock.withLock { requestStorage } }

  static func reset() {
    lock.withLock { requestStorage = [] }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.lock.withLock {
      Self.requestStorage.append(Request(method: request.httpMethod ?? "", url: url))
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let body =
      request.httpMethod == "GET"
      ? #"{"sessions":[{"session_id":"provider-session","cwd":"/tmp/project"}]}"#
      : #"{"ok":true}"#
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
