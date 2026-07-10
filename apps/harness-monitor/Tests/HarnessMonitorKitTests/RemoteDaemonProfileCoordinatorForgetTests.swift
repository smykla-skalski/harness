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

  @Test("Metadata rollback failure still restores the token")
  func metadataRollbackFailureRestoresToken() async throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = SaveFailingRemoteDaemonProfileStore(state: originalState)
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

  @Test("Token deletion failure does not retry deletion or save metadata")
  func tokenDeletionFailureStopsBeforeMetadata() async throws {
    let profile = try remoteProfileFixture()
    let originalState = RemoteDaemonProfileState(
      profiles: [profile],
      activeProfileID: profile.id
    )
    let repository = SaveFailingRemoteDaemonProfileStore(state: originalState)
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

    #expect(repository.saveCallCount == 0)
    #expect(tokenStore.deleteCallCount == 1)
    #expect(try tokenStore.loadToken(profileID: profile.id) == "server-issued-token")
  }

  @Test("Unreadable token does not prevent forgetting the profile")
  func unreadableTokenCanStillBeForgotten() async throws {
    let profile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )
    let tokenStore = ReadFailingRemoteDaemonTokenStore(
      profileID: profile.id,
      token: "corrupted-token"
    )
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore
    )

    let forgotten = try await coordinator.forgetActiveProfile()

    #expect(forgotten == profile)
    #expect(try repository.load() == RemoteDaemonProfileState())
    #expect(tokenStore.deleteCallCount == 1)
    #expect(tokenStore.hasToken(profileID: profile.id) == false)
  }
}

private enum RemoteDaemonForgetTestError: Error {
  case tokenDeletion
  case tokenRead
  case metadataSave
}

private final class ReadFailingRemoteDaemonTokenStore:
  RemoteDaemonTokenPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var tokens: [UUID: String]
  private var recordedDeleteCallCount = 0

  init(profileID: UUID, token: String) {
    self.tokens = [profileID: token]
  }

  var deleteCallCount: Int {
    lock.withLock { recordedDeleteCallCount }
  }

  func hasToken(profileID: UUID) -> Bool {
    lock.withLock { tokens[profileID] != nil }
  }

  func loadToken(profileID: UUID) throws -> String? {
    throw RemoteDaemonForgetTestError.tokenRead
  }

  func saveToken(_ token: String, profileID: UUID) throws {
    lock.withLock { tokens[profileID] = token }
  }

  func deleteToken(profileID: UUID) throws {
    lock.withLock {
      recordedDeleteCallCount += 1
      tokens.removeValue(forKey: profileID)
    }
  }
}

private final class DeleteFailingRemoteDaemonTokenStore:
  RemoteDaemonTokenPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private var tokens: [UUID: String]
  private var recordedDeleteCallCount = 0

  init(profileID: UUID, token: String) {
    self.tokens = [profileID: token]
  }

  func loadToken(profileID: UUID) throws -> String? {
    lock.withLock { tokens[profileID] }
  }

  func saveToken(_ token: String, profileID: UUID) throws {
    lock.withLock { tokens[profileID] = token }
  }

  var deleteCallCount: Int {
    lock.withLock { recordedDeleteCallCount }
  }

  func deleteToken(profileID: UUID) throws {
    try lock.withLock {
      recordedDeleteCallCount += 1
      guard recordedDeleteCallCount > 1 else {
        throw RemoteDaemonForgetTestError.tokenDeletion
      }
      tokens.removeValue(forKey: profileID)
    }
  }
}

private final class SaveFailingRemoteDaemonProfileStore:
  RemoteDaemonProfilePersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private let state: RemoteDaemonProfileState
  private var recordedSaveCallCount = 0

  init(state: RemoteDaemonProfileState) {
    self.state = state
  }

  var saveCallCount: Int {
    lock.withLock { recordedSaveCallCount }
  }

  func load() throws -> RemoteDaemonProfileState {
    state
  }

  func save(_ state: RemoteDaemonProfileState) throws {
    lock.withLock { recordedSaveCallCount += 1 }
    throw RemoteDaemonForgetTestError.metadataSave
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
