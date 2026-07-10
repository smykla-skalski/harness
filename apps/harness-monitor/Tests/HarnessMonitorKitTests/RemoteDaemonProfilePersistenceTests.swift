import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon profile persistence", .serialized)
struct RemoteDaemonProfilePersistenceTests {
  @Test("Stores profile metadata without the bearer token")
  func storesMetadataWithoutToken() throws {
    let suite = "remote-daemon-profile-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let repository = UserDefaultsRemoteDaemonProfileStore(
      defaults: defaults,
      storageKey: "profiles"
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    let profile = try remoteProfileFixture()

    try tokenStore.saveToken("opaque-bearer-secret", profileID: profile.id)
    try repository.save(
      RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )

    let loaded = try repository.load()
    #expect(loaded.profiles == [profile])
    #expect(loaded.activeProfileID == profile.id)
    let storedData = try #require(defaults.data(forKey: "profiles"))
    let storedText = try #require(String(data: storedData, encoding: .utf8))
    #expect(!storedText.contains("opaque-bearer-secret"))
  }

  @Test("Corrupt stored metadata is cleared after reporting the error")
  func corruptMetadataRecoversAfterOneFailure() throws {
    let suite = "remote-daemon-profile-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not-json".utf8), forKey: "profiles")
    let repository = UserDefaultsRemoteDaemonProfileStore(
      defaults: defaults,
      storageKey: "profiles"
    )

    #expect(throws: RemoteDaemonProfileError.invalidStoredProfiles) {
      try repository.load()
    }

    #expect(defaults.data(forKey: "profiles") == nil)
    #expect(try repository.load() == RemoteDaemonProfileState())
  }

  @Test("Resolves the active remote profile without a local manifest")
  func resolvesManifestIndependentConnection() throws {
    let profile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("opaque-bearer-secret", profileID: profile.id)
    let source = StoredRemoteDaemonConnectionSource(
      repository: repository,
      tokenStore: tokenStore
    )

    let connection = try #require(try source.activeConnection())

    #expect(connection.endpoint == profile.endpoint)
    #expect(connection.token == "opaque-bearer-secret")
    #expect(connection.remoteClientID == profile.clientID)
    #expect(connection.serverTrust == .spkiSHA256(profile.serverSPKISHA256))
    #expect(connection.source == .remote(profileID: profile.id))
  }

  @Test("Marks revoked profiles and removes their token")
  func marksRevokedAndDeletesToken() throws {
    let profile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("opaque-bearer-secret", profileID: profile.id)
    let source = StoredRemoteDaemonConnectionSource(
      repository: repository,
      tokenStore: tokenStore
    )
    let revokedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:20:00Z"))

    try source.markRevoked(profileID: profile.id, at: revokedAt)

    let state = try repository.load()
    let revoked = try #require(state.profiles.first)
    #expect(revoked.status == .revoked)
    #expect(revoked.revokedAt == revokedAt)
    #expect(try tokenStore.loadToken(profileID: profile.id) == nil)
    #expect(throws: RemoteDaemonProfileError.self) {
      try source.activeConnection()
    }
  }
}

func remoteProfileFixture() throws -> RemoteDaemonProfile {
  let pairedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:05:00Z"))
  let expiresAt = try #require(ISO8601DateFormatter().date(from: "2026-07-10T04:10:00Z"))
  let id = try #require(UUID(uuidString: "155A50C8-47E8-4D3B-9073-A277E05F6B78"))
  let endpoint = try #require(URL(string: "https://daemon.example.com"))
  return RemoteDaemonProfile(
    id: id,
    endpoint: endpoint,
    clientID: "macos-client-1",
    displayName: "Work Mac",
    platform: "macos",
    role: .operator,
    scopes: ["read", "write"],
    serverSPKISHA256: try RemoteDaemonSPKIPin(
      validating: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ),
    tokenHint: "abcd1234",
    pairedAt: pairedAt,
    pairingExpiresAt: expiresAt,
    status: .active,
    revokedAt: nil
  )
}

final class InMemoryRemoteDaemonProfileStore:
  RemoteDaemonProfilePersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var state: RemoteDaemonProfileState

  init(state: RemoteDaemonProfileState = RemoteDaemonProfileState()) {
    self.state = state
  }

  func load() throws -> RemoteDaemonProfileState {
    lock.withLock { state }
  }

  func save(_ state: RemoteDaemonProfileState) throws {
    lock.withLock { self.state = state }
  }
}

final class RecordingRemoteDaemonTokenStore:
  RemoteDaemonTokenPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var tokens: [UUID: String] = [:]

  func loadToken(profileID: UUID) throws -> String? {
    lock.withLock { tokens[profileID] }
  }

  func saveToken(_ token: String, profileID: UUID) throws {
    lock.withLock { tokens[profileID] = token }
  }

  func deleteToken(profileID: UUID) throws {
    _ = lock.withLock { tokens.removeValue(forKey: profileID) }
  }
}
