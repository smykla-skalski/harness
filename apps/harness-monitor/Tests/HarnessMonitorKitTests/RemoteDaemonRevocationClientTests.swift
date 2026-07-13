import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon revocation client", .serialized)
struct RemoteDaemonRevocationClientTests {
  @Test("Revokes the authenticated client over the pinned remote connection")
  func revokesAuthenticatedClient() async throws {
    RemoteRevocationURLProtocol.reset(status: 200)
    let recorder = RemoteRevocationSessionRecorder()
    let client = HTTPRemoteDaemonRevocationClient(sessionFactory: recorder.session(for:))
    let profile = try remoteProfileFixture()

    try await client.revoke(profile: profile, token: "server-issued-token")

    let request = try #require(RemoteRevocationURLProtocol.lastRequest)
    #expect(request.url?.absoluteString == "https://daemon.example.com/v1/remote/client/revoke")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer server-issued-token")
    #expect(
      request.value(forHTTPHeaderField: "x-harness-remote-client-id")
        == profile.clientID
    )
    #expect(recorder.lastServerTrust == .spkiSHA256(profile.serverSPKISHA256))
  }

  @Test("Treats unauthorized as an already invalid credential")
  func acceptsAlreadyInvalidCredential() async throws {
    RemoteRevocationURLProtocol.reset(status: 401)
    let recorder = RemoteRevocationSessionRecorder()
    let client = HTTPRemoteDaemonRevocationClient(sessionFactory: recorder.session(for:))

    try await client.revoke(
      profile: remoteProfileFixture(),
      token: "already-revoked-token"
    )
  }

  @Test("Surfaces server failures instead of forgetting locally")
  func surfacesServerFailure() async throws {
    RemoteRevocationURLProtocol.reset(status: 503)
    let recorder = RemoteRevocationSessionRecorder()
    let client = HTTPRemoteDaemonRevocationClient(sessionFactory: recorder.session(for:))

    do {
      try await client.revoke(profile: remoteProfileFixture(), token: "server-issued-token")
      Issue.record("Expected revocation failure")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        Issue.record("Expected a server error")
        return
      }
      #expect(code == 503)
    }
  }
}

private final class RemoteRevocationSessionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedServerTrust: HarnessMonitorServerTrust?

  var lastServerTrust: HarnessMonitorServerTrust? {
    lock.withLock { recordedServerTrust }
  }

  func session(for serverTrust: HarnessMonitorServerTrust) -> URLSession {
    lock.withLock { recordedServerTrust = serverTrust }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteRevocationURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class RemoteRevocationURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responseStatus = 200
  nonisolated(unsafe) private static var recordedRequest: URLRequest?

  static var lastRequest: URLRequest? {
    lock.withLock { recordedRequest }
  }

  static func reset(status: Int) {
    lock.withLock {
      responseStatus = status
      recordedRequest = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let status = Self.lock.withLock {
      Self.recordedRequest = request
      return Self.responseStatus
    }
    guard let requestURL = request.url,
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: status,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: HarnessMonitorAPIError.invalidResponse)
      return
    }
    let body = Data(
      "{\"error\":{\"code\":\"REMOTE_CLIENT_REVOKE\",\"message\":\"unavailable\"}}".utf8
    )
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
