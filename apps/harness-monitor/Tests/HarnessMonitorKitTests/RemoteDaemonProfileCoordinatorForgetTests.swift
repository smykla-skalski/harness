import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon profile forgetting", .serialized)
struct RemoteDaemonProfileCoordinatorForgetTests {
  @Test("Token deletion failure preserves profile metadata")
  func tokenDeletionFailurePreservesMetadata() async throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = InMemoryRemoteDaemonProfileStore(state: originalState)
    let tokenStore = DeleteFailingRemoteDaemonTokenStore(
      profileID: profile.id,
      token: "server-issued-token"
    )
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore
    )

    await #expect(throws: RemoteDaemonForgetTestError.tokenDeletion) {
      _ = try await coordinator.forgetActiveProfile()
    }

    #expect(try repository.load() == originalState)
    #expect(try tokenStore.loadToken(profileID: profile.id) == "server-issued-token")
  }

  @Test("Metadata failure restores profile metadata and token")
  func metadataFailureRestoresStateAndToken() async throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = PartiallyFailingRemoteDaemonProfileStore(state: originalState)
    let tokenStore = RecordingRemoteDaemonTokenStore()
    try tokenStore.saveToken("server-issued-token", profileID: profile.id)
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore
    )

    await #expect(throws: RemoteDaemonForgetTestError.metadataSave) {
      _ = try await coordinator.forgetActiveProfile()
    }

    #expect(try repository.load() == originalState)
    #expect(try tokenStore.loadToken(profileID: profile.id) == "server-issued-token")
  }
}

private enum RemoteDaemonForgetTestError: Error {
  case tokenDeletion
  case metadataSave
}

private final class DeleteFailingRemoteDaemonTokenStore:
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
    throw RemoteDaemonForgetTestError.tokenDeletion
  }
}

private final class PartiallyFailingRemoteDaemonProfileStore:
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
      throw RemoteDaemonForgetTestError.metadataSave
    }
  }
}
