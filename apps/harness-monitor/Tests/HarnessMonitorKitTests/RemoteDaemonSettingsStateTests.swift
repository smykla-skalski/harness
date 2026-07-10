import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Remote daemon Settings state")
@MainActor
struct RemoteDaemonSettingsStateTests {
  @Test("Remote profile hides every local daemon action")
  func remoteProfileHidesLocalActions() throws {
    let availability = SettingsDaemonActionAvailability(
      daemonOwnership: .managed,
      usesRemoteDaemon: true
    )

    #expect(!availability.showsManagedControls)
    #expect(!availability.showsExternalDevCommand)
  }

  @Test("Local ownership keeps its matching daemon actions")
  func localOwnershipKeepsMatchingActions() {
    let managed = SettingsDaemonActionAvailability(
      daemonOwnership: .managed,
      usesRemoteDaemon: false
    )
    let external = SettingsDaemonActionAvailability(
      daemonOwnership: .external,
      usesRemoteDaemon: false
    )

    #expect(managed.showsManagedControls)
    #expect(!managed.showsExternalDevCommand)
    #expect(!external.showsManagedControls)
    #expect(external.showsExternalDevCommand)
  }

  @Test("Connection and general snapshots expose the active remote profile")
  func settingsSnapshotsExposeRemoteProfile() throws {
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
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      remoteDaemonServices: RemoteDaemonServices(
        connectionSource: source,
        profileCoordinator: RemoteDaemonProfileCoordinator(
          repository: repository,
          tokenStore: tokenStore,
          claimant: SettingsNeverPairingClaimant()
        )
      )
    )

    let connection = SettingsConnectionSnapshot(store: store)
    let overview = SettingsGeneralOverviewState(store: store)
    let live = SettingsGeneralLiveState(store: store)

    #expect(connection.remoteProfile == profile)
    #expect(connection.remoteActionState == .idle)
    #expect(overview.daemonModeLabel == "Remote")
    #expect(overview.isRemoteDaemon)
    #expect(!overview.showsLaunchAgent)
    #expect(!live.daemonActionAvailability.showsManagedControls)
  }
}

private struct SettingsNeverPairingClaimant: RemoteDaemonPairingClaiming {
  func claim(
    invitation: RemoteDaemonPairingInvitation,
    clientID: String,
    displayName: String,
    platform: String
  ) async throws -> RemoteDaemonPairingClaim {
    throw HarnessMonitorAPIError.invalidResponse
  }
}
