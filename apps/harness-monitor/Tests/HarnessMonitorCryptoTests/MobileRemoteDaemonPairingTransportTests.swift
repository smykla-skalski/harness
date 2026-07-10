import Foundation
import HarnessMonitorCrypto
import XCTest

final class MobileRemoteDaemonPairingTransportTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RemotePairingURLProtocol.reset()
  }

  override func tearDown() {
    RemotePairingURLProtocol.reset()
    super.tearDown()
  }

  func testClaimPostsOneTimeCodeAndClientIdentity() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    RemotePairingURLProtocol.respond(
      statusCode: 201,
      body: """
        {
          "client_id": "ios-device-fingerprint",
          "display_name": "Bart's iPhone",
          "platform": "ios",
          "role": "operator",
          "scopes": ["read", "write"],
          "token": "server-issued-token",
          "token_hint": "abcd1234",
          "paired_at": "2025-07-10T14:33:25Z"
        }
        """
    )
    let session = makeSession()
    let transport = URLSessionMobileRemoteDaemonPairingTransport { _ in session }
    let invitation = try MobileRemoteDaemonPairingInvitation.decode(
      remoteInvitationURL(now: now),
      now: now
    )

    let claim = try await transport.claim(
      invitation: invitation,
      clientID: "ios-device-fingerprint",
      displayName: "Bart's iPhone",
      platform: "ios"
    )

    let request = try XCTUnwrap(RemotePairingURLProtocol.lastRequest)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://daemon.example.com/v1/remote/pair/claim"
    )
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let body = try XCTUnwrap(RemotePairingURLProtocol.lastRequestBody)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    XCTAssertEqual(object["code"], "one-time-code")
    XCTAssertEqual(object["domain"], "daemon.example.com")
    XCTAssertEqual(object["client_id"], "ios-device-fingerprint")
    XCTAssertEqual(object["display_name"], "Bart's iPhone")
    XCTAssertEqual(object["platform"], "ios")
    XCTAssertEqual(claim.token, "server-issued-token")
    XCTAssertEqual(claim.role, .operator)
    XCTAssertEqual(claim.scopes, ["read", "write"])
  }

  func testClaimRejectsServerIdentityMismatch() async throws {
    let now = Date(timeIntervalSince1970: 1_752_124_400)
    RemotePairingURLProtocol.respond(
      statusCode: 200,
      body: """
        {
          "client_id": "different-client",
          "display_name": "Bart's iPhone",
          "platform": "ios",
          "role": "viewer",
          "scopes": ["read"],
          "token": "server-issued-token",
          "token_hint": "abcd1234",
          "paired_at": "2025-07-10T14:33:25Z"
        }
        """
    )
    let session = makeSession()
    let transport = URLSessionMobileRemoteDaemonPairingTransport { _ in session }
    let invitation = try MobileRemoteDaemonPairingInvitation.decode(
      remoteInvitationURL(now: now),
      now: now
    )

    do {
      _ = try await transport.claim(
        invitation: invitation,
        clientID: "ios-device-fingerprint",
        displayName: "Bart's iPhone",
        platform: "ios"
      )
      XCTFail("expected claim mismatch")
    } catch let error as MobileRemoteDaemonPairingError {
      XCTAssertEqual(error, .claimMismatch)
    }
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemotePairingURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func remoteInvitationURL(now: Date) throws -> URL {
    let payload: [String: Any] = [
      "version": 1,
      "endpoint": "https://daemon.example.com",
      "code": "one-time-code",
      "server_spki_sha256": "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY=",
      "role": "operator",
      "scopes": ["read", "write"],
      "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(600)),
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let encoded =
      data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try XCTUnwrap(
      URL(string: "harness://remote-pair?payload=\(encoded)")
    )
  }
}

private final class RemotePairingURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responseStatusCode = 200
  nonisolated(unsafe) private static var responseBody = Data()
  nonisolated(unsafe) private static var capturedRequest: URLRequest?
  nonisolated(unsafe) private static var capturedRequestBody: Data?

  static var lastRequest: URLRequest? {
    lock.withLock { capturedRequest }
  }

  static var lastRequestBody: Data? {
    lock.withLock { capturedRequestBody }
  }

  static func reset() {
    lock.withLock {
      responseStatusCode = 200
      responseBody = Data()
      capturedRequest = nil
      capturedRequestBody = nil
    }
  }

  static func respond(statusCode: Int, body: String) {
    lock.withLock {
      responseStatusCode = statusCode
      responseBody = Data(body.utf8)
    }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let requestBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBodyStream)
    let state = Self.lock.withLock { () -> (Int, Data) in
      Self.capturedRequest = request
      Self.capturedRequestBody = requestBody
      return (Self.responseStatusCode, Self.responseBody)
    }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: state.0,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: state.1)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readBodyStream(_ stream: InputStream) -> Data? {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count >= 0 else { return nil }
      if count == 0 { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
