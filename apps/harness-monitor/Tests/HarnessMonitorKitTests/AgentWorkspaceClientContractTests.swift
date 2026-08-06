import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Agent workspace client contract")
struct AgentWorkspaceClientContractTests {
  @Test("HTTP exposes durable identity and legacy provenance")
  func httpContract() async throws {
    AgentWorkspaceURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AgentWorkspaceURLProtocol.self]
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: URLSession(configuration: configuration)
    )

    let response = try await client.agentWorkspaces()

    #expect(AgentWorkspaceURLProtocol.requestPath == "/v1/agent-workspaces")
    #expect(AgentWorkspaceURLProtocol.requestMethod == "GET")
    assertAgentWorkspaceResponse(response)
  }

  @Test("WebSocket uses the durable workspace query")
  func webSocketContract() async throws {
    let value = try JSONDecoder().decode(
      JSONValue.self,
      from: Data(agentWorkspaceResponseJSON.utf8)
    )
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        #expect(method == .agentWorkspaces)
        #expect(params == nil)
        return value
      }
    )

    assertAgentWorkspaceResponse(try await transport.agentWorkspaces())
  }

  private func assertAgentWorkspaceResponse(_ response: AgentWorkspaceListResponse) {
    #expect(response.workspaces.map(\.workspaceId) == ["workspace-1"])
    #expect(response.workspaces[0].orchestrationAuthority == .legacySession)
    #expect(response.workspaces[0].availability == .available)
    #expect(response.workspaces[0].provenance.daemonId == "daemon-1")
    #expect(response.workspaces[0].provenance.selectedLegacySessionId == "session-1")
    #expect(response.conflicts.map(\.kind) == [.activeOwnerCollision])
    #expect(response.conflicts[0].legacySessionIds == ["session-2", "session-3"])
  }
}

private let agentWorkspaceResponseJSON = #"""
  {
    "workspaces": [{
      "workspace_id": "workspace-1",
      "project_name": "Harness",
      "checkout_name": "main",
      "checkout_root": "/tmp/harness",
      "context_root": "/tmp/harness",
      "is_worktree": false,
      "availability": "available",
      "orchestration_authority": "legacy_session",
      "provenance": {
        "daemon_id": "daemon-1",
        "project_scope_id": "project-scope-1",
        "checkout_id": "checkout-1",
        "source_project_id": "project-1",
        "legacy_session_ids": ["session-1"],
        "selected_legacy_session_id": "session-1",
        "manifest_digest": "digest-1"
      },
      "created_at": "2026-08-06T00:00:00Z",
      "updated_at": "2026-08-06T00:00:01Z"
    }],
    "conflicts": [{
      "daemon_id": "daemon-1",
      "project_scope_id": "project-scope-2",
      "checkout_id": "checkout-2",
      "kind": "active_owner_collision",
      "legacy_session_ids": ["session-2", "session-3"],
      "detail": "multiple active legacy owners"
    }]
  }
  """#

private final class AgentWorkspaceURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var pathStorage: String?
  nonisolated(unsafe) private static var methodStorage: String?

  static var requestPath: String? { lock.withLock { pathStorage } }
  static var requestMethod: String? { lock.withLock { methodStorage } }

  static func reset() {
    lock.withLock {
      pathStorage = nil
      methodStorage = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard
      let url = request.url,
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
    Self.lock.withLock {
      Self.pathStorage = url.path
      Self.methodStorage = request.httpMethod
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(agentWorkspaceResponseJSON.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
