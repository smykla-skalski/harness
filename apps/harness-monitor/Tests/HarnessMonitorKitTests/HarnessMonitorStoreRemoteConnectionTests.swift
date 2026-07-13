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

  @Test("Profile refresh failure clears stale remote mode")
  func profileRefreshFailureClearsRemoteMode() throws {
    let profile = try remoteProfileFixture()
    let source = ToggleRemoteDaemonConnectionSource(profile: profile)
    let repository = InMemoryRemoteDaemonProfileStore()
    let tokenStore = RecordingRemoteDaemonTokenStore()
    let services = RemoteDaemonServices(
      connectionSource: source,
      profileCoordinator: RemoteDaemonProfileCoordinator(
        repository: repository,
        tokenStore: tokenStore,
        claimant: NeverRemoteDaemonPairingClaimant()
      )
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      remoteDaemonServices: services
    )
    #expect(store.usesRemoteDaemon)

    source.failProfileLoads()
    store.refreshRemoteDaemonProfile()

    #expect(!store.usesRemoteDaemon)
    #expect(store.remoteDaemonProfile == nil)
    #expect(store.remoteDaemonActionState.errorMessage != nil)
  }

  @Test("Pairing does not overlap an in-flight remote action")
  func pairingDoesNotOverlapRemoteAction() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.remoteDaemonActionState = .forgetting

    store.pairRemoteDaemon(
      using: .deepLink("harness://remote-pair"),
      displayName: "Work Mac"
    )

    #expect(store.remoteDaemonActionState == .forgetting)
  }

  @Test("Forgetting does not overlap an in-flight remote action")
  func forgettingDoesNotOverlapRemoteAction() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.remoteDaemonActionState = .pairing

    store.forgetRemoteDaemon()

    #expect(store.remoteDaemonActionState == .pairing)
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
        claimant: EchoRemoteDaemonPairingClaimant(),
        revoker: SuccessfulRemoteDaemonRevoker()
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

  @Test("Forgetting a remote daemon reconnects with the local manifest")
  func forgettingRemoteDaemonRestoresLocalManifest() async throws {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController(
      warmUpError: DaemonControlError.daemonDidNotStart,
      usesWarmUpErrorForBootstrap: false
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external,
      remoteDaemonServices: fixture.services
    )
    let localManifestURL = URL(fileURLWithPath: "/tmp/harness-local/manifest.json")
    store.manifestURL = localManifestURL

    await store.bootstrap()
    #expect(store.manifestURL == localManifestURL)

    store.manifestURL = URL(fileURLWithPath: "/var/lib/harness-remote/manifest.json")
    store.forgetRemoteDaemon()
    try await waitUntil {
      guard case .offline = store.connectionState else { return false }
      return !store.usesRemoteDaemon && store.remoteDaemonActionState == .idle
    }

    #expect(store.manifestURL == HarnessMonitorPaths.manifestURLWithoutLiveDiscovery())
    #expect(await daemon.recordedWarmUpCallCount() == 1)
  }

  @Test("Revocation failure keeps the remote profile and does not reconnect locally")
  func revocationFailureKeepsRemoteConnection() async throws {
    let fixture = try RemoteStoreFixture(revoker: FailingRemoteDaemonRevoker())
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    store.forgetRemoteDaemon()
    try await waitUntil { store.remoteDaemonActionState.errorMessage != nil }

    #expect(store.usesRemoteDaemon)
    #expect(store.remoteDaemonProfile == fixture.profile)
    #expect(try fixture.tokenStore.loadToken(profileID: fixture.profile.id) != nil)
    #expect(await daemon.recordedWarmUpCallCount() == 0)
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

  init(
    revoker: any RemoteDaemonClientRevoking = SuccessfulRemoteDaemonRevoker()
  ) throws {
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
        claimant: NeverRemoteDaemonPairingClaimant(),
        revoker: revoker
      )
    )
  }
}

private final class ToggleRemoteDaemonConnectionSource:
  RemoteDaemonConnectionSourcing, @unchecked Sendable
{
  private let lock = NSLock()
  private let profile: RemoteDaemonProfile
  private var shouldFailProfileLoads = false

  init(profile: RemoteDaemonProfile) {
    self.profile = profile
  }

  func failProfileLoads() {
    lock.withLock { shouldFailProfileLoads = true }
  }

  func activeConnection() throws -> HarnessMonitorConnection? {
    nil
  }

  func activeProfile() throws -> RemoteDaemonProfile? {
    let shouldFail = lock.withLock { shouldFailProfileLoads }
    if shouldFail {
      throw RemoteDaemonProfileError.profileNotFound
    }
    return profile
  }

  func markRevoked(profileID: UUID, at date: Date) throws {}
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
