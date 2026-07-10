import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon profile activation", .serialized)
struct RemoteDaemonProfileCoordinatorActivationTests {
  @Test("Unreadable old token does not block profile replacement")
  func unreadableOldTokenCanBeReplaced() async throws {
    let existingProfile = try remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(
        profiles: [existingProfile],
        activeProfileID: existingProfile.id
      )
    )
    let tokenStore = OldTokenReadFailingStore(
      profileID: existingProfile.id,
      token: "corrupted-old-token"
    )
    let replacementID = try #require(
      UUID(uuidString: "29F770D1-E9A1-4C52-9301-13DC6957D0A9")
    )
    let coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore,
      claimant: SuccessfulReplacementClaimant(),
      profileIDGenerator: { replacementID },
      clientIDGenerator: { _ in existingProfile.clientID }
    )
    let invitation = try RemoteDaemonPairingInput.manual(
      endpoint: "https://daemon.example.com",
      code: "one-time-code",
      serverSPKISHA256: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
    ).invitation(now: existingProfile.pairedAt)

    let replacement = try await coordinator.pair(
      invitation: invitation,
      displayName: "Replacement Mac"
    )

    #expect(replacement.id == replacementID)
    #expect(tokenStore.token(profileID: existingProfile.id) == nil)
    #expect(tokenStore.token(profileID: replacementID) == "replacement-token")
    #expect(
      try repository.load()
        == RemoteDaemonProfileState(profiles: [replacement], activeProfileID: replacementID)
    )
  }
}

private enum RemoteDaemonActivationTestError: Error {
  case unreadableToken
}

private struct SuccessfulReplacementClaimant: RemoteDaemonPairingClaiming {
  func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim {
    RemoteDaemonPairingClaim(
      clientID: clientID,
      displayName: displayName,
      platform: platform,
      role: .operator,
      scopes: ["read", "write"],
      token: "replacement-token",
      tokenHint: "newtoken",
      pairedAt: .now
    )
  }
}

private final class OldTokenReadFailingStore:
  RemoteDaemonTokenPersisting, @unchecked Sendable
{
  private let lock = NSLock()
  private let unreadableProfileID: UUID
  private var tokens: [UUID: String]

  init(profileID: UUID, token: String) {
    self.unreadableProfileID = profileID
    self.tokens = [profileID: token]
  }

  func token(profileID: UUID) -> String? {
    lock.withLock { tokens[profileID] }
  }

  func loadToken(profileID: UUID) throws -> String? {
    if profileID == unreadableProfileID {
      throw RemoteDaemonActivationTestError.unreadableToken
    }
    return token(profileID: profileID)
  }

  func saveToken(_ token: String, profileID: UUID) throws {
    lock.withLock { tokens[profileID] = token }
  }

  func deleteToken(profileID: UUID) throws {
    _ = lock.withLock { tokens.removeValue(forKey: profileID) }
  }
}
