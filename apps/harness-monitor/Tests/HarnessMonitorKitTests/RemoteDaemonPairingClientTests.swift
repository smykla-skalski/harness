import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon pairing client", .serialized)
struct RemoteDaemonPairingClientTests {
  @Test("Claims the public pairing route without an Authorization header")
  func claimsPublicPairingRoute() async throws {
    RemotePairingURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemotePairingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HTTPRemoteDaemonPairingClient(sessionFactory: { _ in session })
    let invitation = try pairingInvitationFixture()

    let claim = try await client.claim(
      invitation: invitation,
      clientID: "macos-client-1",
      displayName: "Work Mac",
      platform: "macos"
    )

    #expect(claim.clientID == "macos-client-1")
    #expect(claim.role == .operator)
    #expect(claim.scopes == ["read", "write"])
    #expect(claim.token == "server-issued-token")
    let request = try #require(RemotePairingURLProtocol.lastRequest)
    #expect(request.url?.absoluteString == "https://daemon.example.com/v1/remote/pair/claim")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let body = try #require(RemotePairingURLProtocol.lastBody)
    let json = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: String]
    )
    #expect(json["code"] == "manual-code-value")
    #expect(json["domain"] == "daemon.example.com")
    #expect(json["client_id"] == "macos-client-1")
    #expect(json["display_name"] == "Work Mac")
    #expect(json["platform"] == "macos")
  }

  @Test("Persists token and metadata as one profile activation")
  func persistsClaimedProfile() async throws {
    let repository = InMemoryRemoteDaemonProfileStore()
    let tokenStore = RecordingRemoteDaemonTokenStore()
    let claimant = StubRemoteDaemonPairingClaimant(result: .success(try claimFixture()))
    let profileID = UUID(uuidString: "29F770D1-E9A1-4C52-9301-13DC6957D0A9")!
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore,
      claimant: claimant,
      profileIDGenerator: { profileID },
      clientIDGenerator: { _ in "macos-client-1" }
    )

    let profile = try await coordinator.pair(
      invitation: pairingInvitationFixture(),
      displayName: "Work Mac"
    )

    #expect(profile.id == profileID)
    #expect(profile.endpoint.absoluteString == "https://daemon.example.com")
    #expect(profile.clientID == "macos-client-1")
    #expect(profile.role == .operator)
    #expect(try tokenStore.loadToken(profileID: profileID) == "server-issued-token")
    let state = try repository.load()
    #expect(state.activeProfileID == profileID)
    #expect(state.profiles == [profile])
  }

  @Test("Rolls back the Keychain token when metadata persistence fails")
  func rollsBackTokenOnMetadataFailure() async throws {
    let tokenStore = RecordingRemoteDaemonTokenStore()
    let profileID = UUID(uuidString: "29F770D1-E9A1-4C52-9301-13DC6957D0A9")!
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: ThrowingRemoteDaemonProfileStore(),
      tokenStore: tokenStore,
      claimant: StubRemoteDaemonPairingClaimant(result: .success(try claimFixture())),
      profileIDGenerator: { profileID },
      clientIDGenerator: { _ in "macos-client-1" }
    )

    await #expect(throws: RemoteDaemonProfileError.self) {
      _ = try await coordinator.pair(
        invitation: pairingInvitationFixture(),
        displayName: "Work Mac"
      )
    }

    #expect(try tokenStore.loadToken(profileID: profileID) == nil)
  }

  @Test("Forgets the active profile metadata and token")
  func forgetsActiveProfile() async throws {
    let profile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("server-issued-token", profileID: profile.id)
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore,
      claimant: StubRemoteDaemonPairingClaimant(result: .success(try claimFixture()))
    )

    let forgotten = try await coordinator.forgetActiveProfile()

    #expect(forgotten == profile)
    #expect(try repository.load() == RemoteDaemonProfileState())
    #expect(try tokenStore.loadToken(profileID: profile.id) == nil)
  }

  @Test("Replacing a duplicate client removes its old Keychain token")
  func replacingDuplicateClientDeletesOldToken() async throws {
    let existingProfile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(
        profiles: [existingProfile],
        activeProfileID: existingProfile.id
      )
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("old-server-token", profileID: existingProfile.id)
    let replacementID = try #require(
      UUID(uuidString: "29F770D1-E9A1-4C52-9301-13DC6957D0A9")
    )
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore,
      claimant: StubRemoteDaemonPairingClaimant(result: .success(try claimFixture())),
      profileIDGenerator: { replacementID },
      clientIDGenerator: { _ in existingProfile.clientID }
    )

    let replacement = try await coordinator.pair(
      invitation: pairingInvitationFixture(),
      displayName: "Work Mac"
    )

    #expect(try tokenStore.loadToken(profileID: existingProfile.id) == nil)
    #expect(try tokenStore.loadToken(profileID: replacement.id) == "server-issued-token")
    #expect(
      try repository.load()
        == RemoteDaemonProfileState(profiles: [replacement], activeProfileID: replacement.id)
    )
  }
}

private func pairingInvitationFixture() throws -> RemoteDaemonPairingInvitation {
  let expiresAt = try #require(
    ISO8601DateFormatter().date(from: "2026-07-10T05:00:00Z")
  )
  let now = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:00:00Z"))
  let endpoint = try #require(URL(string: "https://daemon.example.com"))
  return try RemoteDaemonPairingInvitation(
    endpoint: endpoint,
    code: "manual-code-value",
    serverSPKISHA256: RemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ),
    role: .operator,
    scopes: ["read", "write"],
    expiresAt: expiresAt,
    now: now
  )
}

private func claimFixture() throws -> RemoteDaemonPairingClaim {
  let pairedAt = try #require(
    ISO8601DateFormatter().date(from: "2026-07-10T04:05:00Z")
  )
  return RemoteDaemonPairingClaim(
    clientID: "macos-client-1",
    displayName: "Work Mac",
    platform: "macos",
    role: .operator,
    scopes: ["read", "write"],
    token: "server-issued-token",
    tokenHint: "abcd1234",
    pairedAt: pairedAt
  )
}

private final class StubRemoteDaemonPairingClaimant:
  RemoteDaemonPairingClaiming, @unchecked Sendable
{
  let result: Result<RemoteDaemonPairingClaim, Error>

  init(result: Result<RemoteDaemonPairingClaim, Error>) {
    self.result = result
  }

  func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim {
    try result.get()
  }
}

private struct ThrowingRemoteDaemonProfileStore: RemoteDaemonProfilePersisting {
  func load() throws -> RemoteDaemonProfileState {
    RemoteDaemonProfileState()
  }

  func save(_ state: RemoteDaemonProfileState) throws {
    throw RemoteDaemonProfileError.invalidStoredProfiles
  }
}

private final class RemotePairingURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequest: URLRequest?
  nonisolated(unsafe) private static var recordedBody: Data?

  static var lastRequest: URLRequest? {
    lock.withLock { recordedRequest }
  }

  static var lastBody: Data? {
    lock.withLock { recordedBody }
  }

  static func reset() {
    lock.withLock {
      recordedRequest = nil
      recordedBody = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let requestBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readBodyStream)
    Self.lock.withLock {
      Self.recordedRequest = request
      Self.recordedBody = requestBody
    }
    let body = """
      {
        "client_id": "macos-client-1",
        "display_name": "Work Mac",
        "platform": "macos",
        "role": "operator",
        "scopes": ["read", "write"],
        "token": "server-issued-token",
        "token_hint": "abcd1234",
        "paired_at": "2026-07-10T04:05:00Z"
      }
      """
    guard let requestURL = request.url,
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: HarnessMonitorAPIError.invalidResponse)
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
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
