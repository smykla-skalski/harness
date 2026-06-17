import Foundation
import Testing

@testable import HarnessMonitorKit

/// Proves archiveSession decodes through the generated SessionArchiveResponseWire
/// on the plain PolicyWireCoding decoder on BOTH transports, and encodes the
/// request through SessionArchiveRequestWire. The daemon emits snake_case
/// (session_id, archived_at) and the wire type owns that shape via explicit
/// CodingKeys; the rich SessionArchiveResponse keeps its idiomatic property
/// names. Previously both transports decoded the hand model under
/// .convertFromSnakeCase - this pins the static wire path end-to-end.
@Suite("Session archive decode reroute")
struct SessionArchiveRerouteContractTests {
  private let responseJSON = #"{"session_id":"session-7","archived_at":"2026-06-17T09:15:00Z"}"#

  @Test("HTTP client decodes the archive response through the wire type")
  func httpArchiveReroute() async throws {
    SessionArchiveURLProtocol.reset()
    SessionArchiveURLProtocol.configure(status: 200, body: responseJSON)
    let client = try makeHTTPClient()

    let response = try await client.archiveSession(
      sessionID: "session-7",
      request: SessionArchiveRequest(actor: "leader")
    )

    assertArchive(response)
    #expect(SessionArchiveURLProtocol.lastRequestPath == "/v1/sessions/session-7/archive")
    #expect(SessionArchiveURLProtocol.lastRequestMethod == "POST")
    #expect(SessionArchiveURLProtocol.lastRequestBody?["actor"] as? String == "leader")
  }

  @Test("WebSocket transport decodes the archive response through the wire type")
  func webSocketArchiveReroute() async throws {
    let probe = RPCProbe()
    let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(responseJSON.utf8))
    let transport = try makeWebSocketTransport(probe: probe, response: fixture)

    let response = try await transport.archiveSession(
      sessionID: "session-7",
      request: SessionArchiveRequest(actor: "leader")
    )

    assertArchive(response)

    let calls = await probe.calls
    #expect(calls.map(\.method) == [.sessionArchive])
    let params = try #require(calls.first?.params)
    guard case .object(let fields) = params else {
      Issue.record("expected object params, got \(params)")
      return
    }
    #expect(fields["session_id"] == .string("session-7"))
    #expect(fields["actor"] == .string("leader"))
  }

  private func assertArchive(_ response: SessionArchiveResponse) {
    #expect(response.sessionId == "session-7")
    #expect(response.archivedAt == "2026-06-17T09:15:00Z")
  }

  private func makeHTTPClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SessionArchiveURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: session
    )
  }

  private func makeWebSocketTransport(
    probe: RPCProbe,
    response: JSONValue
  ) throws -> WebSocketTransport {
    WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        return response
      }
    )
  }
}

private final class SessionArchiveURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestPath: String?
  nonisolated(unsafe) private static var requestMethod: String?
  nonisolated(unsafe) private static var requestBody: [String: Any]?
  nonisolated(unsafe) private static var responseStatus = 200
  nonisolated(unsafe) private static var responseBody = ""

  static var lastRequestPath: String? { lock.withLock { requestPath } }
  static var lastRequestMethod: String? { lock.withLock { requestMethod } }
  static var lastRequestBody: [String: Any]? { lock.withLock { requestBody } }

  static func reset() {
    lock.withLock {
      requestPath = nil
      requestMethod = nil
      requestBody = nil
      responseStatus = 200
      responseBody = ""
    }
  }

  static func configure(status: Int, body: String) {
    lock.withLock {
      responseStatus = status
      responseBody = body
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let (status, body): (Int, String) = Self.lock.withLock {
      (Self.responseStatus, Self.responseBody)
    }
    Self.lock.withLock {
      Self.requestPath = url.path
      Self.requestMethod = request.httpMethod
      Self.requestBody = Self.jsonBody(for: request)
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func jsonBody(for request: URLRequest) -> [String: Any]? {
    guard
      let data = bodyData(for: request),
      !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object
  }

  private static func bodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return nil
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
