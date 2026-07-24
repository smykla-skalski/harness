import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Remote daemon profile revocation", .serialized)
struct RemoteDaemonProfileCoordinatorRevocationTests {
  @Test("Revokes an active server credential before removing local state")
  func revokesBeforeForgetting() async throws {
    let fixture = try RevocationCoordinatorFixture()

    let forgotten = try await fixture.coordinator.forgetActiveProfile()

    #expect(forgotten?.profile == fixture.profile)
    #expect(forgotten?.serverRevoked == true)
    #expect(
      await fixture.revoker.recordedCalls()
        == [.init(clientID: fixture.profile.clientID, token: "server-issued-token")]
    )
    #expect(try fixture.repository.load() == RemoteDaemonProfileState())
    #expect(try fixture.tokenStore.loadToken(profileID: fixture.profile.id) == nil)
  }

  @Test("Revocation failure still forgets locally and reports the live token")
  func revocationFailureStillForgetsLocally() async throws {
    let fixture = try RevocationCoordinatorFixture(revocationFails: true)

    let forgotten = try await fixture.coordinator.forgetActiveProfile()

    #expect(forgotten?.profile == fixture.profile)
    #expect(forgotten?.serverRevoked == false)
    #expect(try fixture.repository.load() == RemoteDaemonProfileState())
    #expect(try fixture.tokenStore.loadToken(profileID: fixture.profile.id) == nil)
  }

  @Test("Already revoked profiles are removed without another server call")
  func alreadyRevokedProfileSkipsServerCall() async throws {
    let activeProfile = try remoteProfileFixture()
    let revokedProfile = activeProfile.markingRevoked(at: .now)
    let fixture = try RevocationCoordinatorFixture(profile: revokedProfile)

    let forgotten = try await fixture.coordinator.forgetActiveProfile()

    #expect(forgotten?.serverRevoked == true)
    #expect(await fixture.revoker.recordedCalls().isEmpty)
    #expect(try fixture.repository.load() == RemoteDaemonProfileState())
    #expect(try fixture.tokenStore.loadToken(profileID: revokedProfile.id) == nil)
  }

  @Test("Missing active token still forgets locally without contacting the server")
  func missingTokenStillForgetsLocally() async throws {
    let fixture = try RevocationCoordinatorFixture(storesToken: false)

    let forgotten = try await fixture.coordinator.forgetActiveProfile()

    #expect(forgotten?.serverRevoked == false)
    #expect(await fixture.revoker.recordedCalls().isEmpty)
    #expect(try fixture.repository.load() == RemoteDaemonProfileState())
  }
}

private struct RevocationCoordinatorFixture {
  let profile: RemoteDaemonProfile
  let repository: InMemoryRemoteDaemonProfileStore
  let tokenStore: RecordingRemoteDaemonTokenStore
  let revoker: RecordingRemoteDaemonRevoker
  let coordinator: RemoteDaemonProfileCoordinator

  init(
    profile: RemoteDaemonProfile? = nil,
    storesToken: Bool = true,
    revocationFails: Bool = false
  ) throws {
    let profile = try profile ?? remoteProfileFixture()
    let repository = InMemoryRemoteDaemonProfileStore(
      state: RemoteDaemonProfileState(profiles: [profile], activeProfileID: profile.id)
    )
    let tokenStore = RecordingRemoteDaemonTokenStore()
    if storesToken {
      try tokenStore.saveToken("server-issued-token", profileID: profile.id)
    }
    let revoker = RecordingRemoteDaemonRevoker(revocationFails: revocationFails)
    self.profile = profile
    self.repository = repository
    self.tokenStore = tokenStore
    self.revoker = revoker
    self.coordinator = RemoteDaemonProfileCoordinator(
      repository: repository,
      tokenStore: tokenStore,
      revoker: revoker
    )
  }
}

private enum RemoteDaemonRevocationTestError: Error {
  case rejected
}

private actor RecordingRemoteDaemonRevoker: RemoteDaemonClientRevoking {
  struct Call: Equatable {
    let clientID: String
    let token: String
  }

  private let revocationFails: Bool
  private var calls: [Call] = []

  init(revocationFails: Bool) {
    self.revocationFails = revocationFails
  }

  func revoke(profile: RemoteDaemonProfile, token: String) async throws {
    calls.append(Call(clientID: profile.clientID, token: token))
    if revocationFails {
      throw RemoteDaemonRevocationTestError.rejected
    }
  }

  func recordedCalls() -> [Call] {
    calls
  }
}
