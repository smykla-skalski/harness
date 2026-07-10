import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon connection revocation", .serialized)
struct RemoteDaemonConnectionSourceRevocationTests {
  @Test("Token deletion failure preserves active profile metadata")
  func tokenDeletionFailurePreservesMetadata() throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = InMemoryRemoteDaemonProfileStore(state: originalState)
    let tokenStore = RevocationDeleteFailingTokenStore(
      profileID: profile.id,
      token: "server-issued-token"
    )
    let source = StoredRemoteDaemonConnectionSource(
      repository: repository,
      tokenStore: tokenStore
    )

    #expect(throws: RemoteDaemonRevocationTestError.tokenDeletion) {
      try source.markRevoked(profileID: profile.id, at: .now)
    }

    #expect(try repository.load() == originalState)
    #expect(try tokenStore.loadToken(profileID: profile.id) == "server-issued-token")
  }

  @Test("Metadata failure restores active profile metadata and token")
  func metadataFailureRestoresStateAndToken() throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = PartiallyFailingRevocationProfileStore(state: originalState)
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("server-issued-token", profileID: profile.id)
    let source = StoredRemoteDaemonConnectionSource(
      repository: repository,
      tokenStore: tokenStore
    )

    #expect(throws: RemoteDaemonRevocationTestError.metadataSave) {
      try source.markRevoked(profileID: profile.id, at: .now)
    }

    #expect(try repository.load() == originalState)
    #expect(try tokenStore.loadToken(profileID: profile.id) == "server-issued-token")
  }
}

private enum RemoteDaemonRevocationTestError: Error {
  case tokenDeletion
  case metadataSave
}

private final class RevocationDeleteFailingTokenStore:
  RemoteDaemonTokenPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var tokens: [UUID: String]

  init(profileID: UUID, token: String) {
    self.tokens = [profileID: token]
  }

  func loadToken(profileID: UUID) throws -> String? {
    lock.withLock { tokens[profileID] }
  }

  func saveToken(_ token: String, profileID: UUID) throws {
    lock.withLock { tokens[profileID] = token }
  }

  func deleteToken(profileID: UUID) throws {
    throw RemoteDaemonRevocationTestError.tokenDeletion
  }
}

private final class PartiallyFailingRevocationProfileStore:
  RemoteDaemonProfilePersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var state: RemoteDaemonProfileState
  private var shouldFailSave = true

  init(state: RemoteDaemonProfileState) {
    self.state = state
  }

  func load() throws -> RemoteDaemonProfileState {
    lock.withLock { state }
  }

  func save(_ state: RemoteDaemonProfileState) throws {
    try lock.withLock {
      self.state = state
      guard shouldFailSave else { return }
      shouldFailSave = false
      throw RemoteDaemonRevocationTestError.metadataSave
    }
  }
}
