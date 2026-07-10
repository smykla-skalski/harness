import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor remote daemon store", .serialized)
@MainActor
struct HarnessMonitorStoreRemoteConnectionTests {
  @Test("Remote bootstrap bypasses local launch agent and manifest warm-up")
  func remoteBootstrapUsesDirectClient() async throws {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.usesRemoteDaemon)
    #expect(store.remoteDaemonProfile == fixture.profile)
    #expect(await daemon.recordedBootstrapCallCount() == 1)
    #expect(await daemon.recordedWarmUpCallCount() == 0)
    #expect(await daemon.recordedLaunchAgentStateCallCount() == 0)
  }

  @Test("Mobile relay uses the remote client without local daemon warm-up")
  func mobileRelayUsesRemoteClient() async throws {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    let client = try await store.clientForMobileRelay()

    #expect(await daemon.recordedBootstrapCallCount() == 1)
    #expect(await daemon.recordedWarmUpCallCount() == 0)
    await client.shutdown()
  }

  @Test("Remote 401 refreshes the cached profile as revoked")
  func remoteUnauthorizedRefreshesRevokedProfile() async throws {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController(
      bootstrapError: HarnessMonitorAPIError.server(code: 401, message: "unauthorized")
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    await store.bootstrap()

    #expect(store.remoteDaemonProfile?.status == .revoked)
    #expect(try fixture.tokenStore.loadToken(profileID: fixture.profile.id) == nil)
    if case .offline(let reason) = store.connectionState {
      #expect(reason.localizedCaseInsensitiveContains("unauthorized"))
    } else {
      Issue.record("expected remote bootstrap to be offline")
    }
  }

  @Test("Queued pairing and forget actions switch between remote and local clients")
  func queuedPairAndForgetSwitchConnectionSources() async throws {
    let repository = InMemoryRemoteDaemonProfileStore()
    let tokenStore = RecordingRemoteDaemonTokenStore()
    let source = StoredRemoteDaemonConnectionSource(
      repository: repository,
      tokenStore: tokenStore
    )
    let services = RemoteDaemonServices(
      connectionSource: source,
      profileCoordinator: RemoteDaemonProfileCoordinator(
        repository: repository,
        tokenStore: tokenStore,
        claimant: EchoRemoteDaemonPairingClaimant()
      )
    )
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: services
    )

    store.pairRemoteDaemon(
      using: .manual(
        endpoint: "https://daemon.example.com",
        code: "one-time-code",
        serverSPKISHA256: "sha256/CQ8Rnn313xPUG+5zny4xTooD6AxAsZr/anC/ea4bTIY="
      ),
      displayName: "Work Mac"
    )
    try await waitUntil { store.remoteDaemonProfile != nil && store.connectionState == .online }

    let pairedProfile = try #require(store.remoteDaemonProfile)
    #expect(store.usesRemoteDaemon)
    #expect(try tokenStore.loadToken(profileID: pairedProfile.id) == "server-issued-token")
    #expect(await daemon.recordedBootstrapCallCount() == 1)

    store.forgetRemoteDaemon()
    try await waitUntil { !store.usesRemoteDaemon && store.connectionState == .online }

    #expect(try repository.load() == RemoteDaemonProfileState())
    #expect(try tokenStore.loadToken(profileID: pairedProfile.id) == nil)
    #expect(await daemon.recordedWarmUpCallCount() == 1)
  }

  private func waitUntil(
    _ condition: @MainActor () -> Bool
  ) async throws {
    for _ in 0..<100 {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for the remote daemon action")
  }
}

private struct RemoteStoreFixture {
  let profile: RemoteDaemonProfile
  let tokenStore: RecordingRemoteDaemonTokenStore
  let services: RemoteDaemonServices

  init() throws {
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
    self.profile = profile
    self.tokenStore = tokenStore
    self.services = RemoteDaemonServices(
      connectionSource: source,
      profileCoordinator: RemoteDaemonProfileCoordinator(
        repository: repository,
        tokenStore: tokenStore,
        claimant: NeverRemoteDaemonPairingClaimant()
      )
    )
  }
}

private struct NeverRemoteDaemonPairingClaimant: RemoteDaemonPairingClaiming {
  func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim {
    throw HarnessMonitorAPIError.invalidResponse
  }
}

private struct EchoRemoteDaemonPairingClaimant: RemoteDaemonPairingClaiming {
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
      token: "server-issued-token",
      tokenHint: "abcd1234",
      pairedAt: .now
    )
  }
}
