import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor API error formatting", .serialized)
struct HarnessMonitorAPIErrorTests {
  @Test("Nested daemon error payloads normalize to the inner semantic message")
  func nestedDaemonErrorPayloadNormalizesToInnerMessage() {
    let message =
      #"{"error":{"details":null,"message":"session not active: "#
      + #"managed agent 'agent-tui-1' not found","code":"KSRCLI090"}}"#
    let error = HarnessMonitorAPIError.server(
      code: 400,
      message: message
    )

    #expect(
      error.errorDescription
        == "Daemon error 400: session not active: managed agent 'agent-tui-1' not found"
    )
    #expect(error.serverMessage == "session not active: managed agent 'agent-tui-1' not found")
    #expect(error.serverSemanticCode == "KSRCLI090")
  }

  @Test("Plain daemon error payloads keep their original message")
  func plainDaemonErrorPayloadKeepsOriginalMessage() {
    let error = HarnessMonitorAPIError.server(code: 503, message: "daemon snapshot warming up")

    #expect(error.errorDescription == "Daemon error 503: daemon snapshot warming up")
    #expect(error.serverMessage == "daemon snapshot warming up")
    #expect(error.serverSemanticCode == nil)
  }

  @Test("Sandbox disabled ACP errors use actionable host bridge copy")
  func sandboxDisabledAcpErrorsUseActionableHostBridgeCopy() {
    let error = HarnessMonitorAPIError.server(
      code: 501,
      message: "sandbox-disabled - acp.host-bridge"
    )

    #expect(
      error.errorDescription
        == """
        ACP project access isn't available on the shared host bridge. Start the \
        host bridge or enable ACP and try again.
        """
    )
    #expect(error.serverMessage == "sandbox-disabled - acp.host-bridge")
    #expect(error.serverSemanticCode == nil)
  }

  @Test("ACP disabled semantic errors map to typed localized copy")
  func acpDisabledSemanticErrorsMapToTypedLocalizedCopy() {
    let error = HarnessMonitorAPIClient.decodeError(
      statusCode: 503,
      data: Data(
        #"{"error":{"code":"ACP_DISABLED","message":"ACP disabled by feature flag","details":[]}}"#
          .utf8
      )
    )

    #expect(error.serverSemanticCode == "ACP_DISABLED")
    #expect(error.acpServiceError == .disabled)
    #expect(
      error.errorDescription
        == "ACP isn't available in this daemon session. Enable ACP and try again"
    )
  }

  @Test("Session-scope semantic errors map to typed localized copy")
  func sessionScopeSemanticErrorsMapToTypedLocalizedCopy() {
    let error = HarnessMonitorAPIClient.decodeError(
      statusCode: 403,
      data: Data(
        #"{"error":{"code":"SESSION_SCOPE_DENIED","message":"session scope denied","details":[]}}"#
          .utf8
      )
    )

    #expect(error.serverSemanticCode == "SESSION_SCOPE_DENIED")
    #expect(error.acpServiceError == .sessionScopeDenied)
    #expect(
      error.errorDescription
        == "ACP access is limited to the active session. Switch to the matching session and try again"
    )
  }

  @Test("GitHub 401 server errors surface as an actionable secrets message")
  func githubUnauthorizedSurfacesAsActionableSecretsMessage() {
    let envelope =
      #"{"error":{"code":"WORKFLOW_IO","message":"dependency-updates github "#
      + #"request failed: GitHub API returned 401 Unauthorized: Bad credentials. "#
      + #"Check that the GitHub token is valid"}}"#
    let error = HarnessMonitorAPIError.server(code: 400, message: envelope)

    #expect(
      error.errorDescription
        == """
        GitHub rejected the configured token (HTTP 401 Bad credentials). The token \
        may have expired or been revoked. Update it in Settings > Secrets and try again
        """
    )
  }

  @Test("HTTP decode failures post daemon telemetry")
  func httpDecodeFailuresPostDaemonTelemetry() async throws {
    APIErrorTelemetryURLProtocol.reset()
    APIErrorTelemetryURLProtocol.configure(
      path: "/v1/sessions/sess-1/managed-agents",
      status: 200,
      body: "{}"
    )
    APIErrorTelemetryURLProtocol.configure(
      path: "/v1/daemon/telemetry",
      status: 200,
      body: #"{"recorded_at":"2026-05-04T15:00:00Z"}"#
    )

    let client = makeTelemetryClient()

    do {
      _ = try await client.managedAgents(sessionID: "sess-1")
      Issue.record("expected a decoding failure")
    } catch {}

    let telemetryBody = try await awaitAPIErrorTelemetryBody()
    #expect(telemetryBody.contains(#""kind":"decode_failure""#))
    #expect(telemetryBody.contains(#""source":"swift.http.response""#))
    #expect(
      telemetryBody.contains(#"GET \/v1\/sessions\/sess-1\/managed-agents decode failed"#)
    )
  }

  @Test("Malformed SSE frames post daemon telemetry")
  func malformedSSEFramesPostDaemonTelemetry() async throws {
    APIErrorTelemetryURLProtocol.reset()
    APIErrorTelemetryURLProtocol.configure(
      path: "/v1/stream",
      status: 200,
      body: #"data: {}"# + "\n\n",
      contentType: "text/event-stream"
    )
    APIErrorTelemetryURLProtocol.configure(
      path: "/v1/daemon/telemetry",
      status: 200,
      body: #"{"recorded_at":"2026-05-04T15:00:02Z"}"#
    )

    let client = makeTelemetryClient()
    let stream = await client.globalStream()
    var iterator = stream.makeAsyncIterator()
    _ = try await iterator.next()

    let telemetryBody = try await awaitAPIErrorTelemetryBody()
    #expect(telemetryBody.contains(#""kind":"decode_failure""#))
    #expect(telemetryBody.contains(#""source":"swift.http.stream""#))
    #expect(telemetryBody.contains(#"SSE frame for \/v1\/stream decode failed"#))
  }
}

private func makeTelemetryClient() -> HarnessMonitorAPIClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [APIErrorTelemetryURLProtocol.self]
  let session = URLSession(configuration: configuration)
  guard let endpoint = URL(string: "http://127.0.0.1:9999") else {
    preconditionFailure("expected valid test endpoint")
  }
  return HarnessMonitorAPIClient(
    connection: HarnessMonitorConnection(
      endpoint: endpoint,
      token: "token"
    ),
    session: session
  )
}

private struct APIErrorResponsePlan {
  let status: Int
  let body: String
  let contentType: String
}

private final class APIErrorTelemetryURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static let notFoundResponse = APIErrorResponsePlan(
    status: 404,
    body: #"{"error":"not-found"}"#,
    contentType: "application/json"
  )
  nonisolated(unsafe) private static var responseByPath: [String: APIErrorResponsePlan] = [:]
  nonisolated(unsafe) private static var telemetryBody: String?

  static var lastTelemetryBody: String? { lock.withLock { telemetryBody } }

  static func reset() {
    lock.withLock {
      responseByPath = [:]
      telemetryBody = nil
    }
  }

  static func configure(
    path: String,
    status: Int,
    body: String,
    contentType: String = "application/json"
  ) {
    lock.withLock {
      responseByPath[path] = APIErrorResponsePlan(
        status: status,
        body: body,
        contentType: contentType
      )
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    let responsePlan = Self.lock.withLock { () -> APIErrorResponsePlan in
      if url.path == "/v1/daemon/telemetry" {
        Self.telemetryBody = requestBodyString(from: request)
      }
      return Self.responseByPath[url.path] ?? Self.notFoundResponse
    }

    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: responsePlan.status,
        httpVersion: nil,
        headerFields: ["Content-Type": responsePlan.contentType]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(responsePlan.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func requestBodyString(from request: URLRequest) -> String? {
  if let body = request.httpBody {
    return String(data: body, encoding: .utf8)
  }
  guard let stream = request.httpBodyStream else {
    return nil
  }

  stream.open()
  defer { stream.close() }

  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count <= 0 {
      break
    }
    data.append(buffer, count: count)
  }

  return data.isEmpty ? nil : String(data: data, encoding: .utf8)
}

private struct AwaitTelemetryTimeoutError: Error {}

private func awaitAPIErrorTelemetryBody() async throws -> String {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(1)

  while clock.now < deadline {
    if let body = APIErrorTelemetryURLProtocol.lastTelemetryBody {
      return body
    }
    try await Task.sleep(for: .milliseconds(10))
  }

  throw AwaitTelemetryTimeoutError()
}
