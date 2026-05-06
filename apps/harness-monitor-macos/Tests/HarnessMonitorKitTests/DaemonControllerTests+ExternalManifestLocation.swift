import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon controller external manifest location")
struct DaemonControllerExternalManifestLocationTests {
  @Test("relaunch reuses the last live external manifest path when no location override is set")
  func relaunchReusesRememberedExternalManifestPath() async throws {
    let defaultsSuite = "DaemonControllerExternalManifestLocationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defer {
      defaults.removePersistentDomain(forName: defaultsSuite)
    }

    let liveEndpoint = "http://127.0.0.1:65531"

    try await withTempDaemonFixture(
      pid: UInt32(getpid()),
      endpoint: liveEndpoint
    ) { rememberedEnvironment in
      let seedingController = DaemonController(
        environment: rememberedEnvironment,
        transportPreference: .http,
        launchAgentManager: RecordingLaunchAgentManager(state: .notRegistered),
        ownership: .external,
        sessionFactory: { _ in PreviewHarnessClient() },
        endpointProbe: { endpoint in endpoint.absoluteString == liveEndpoint },
        externalManifestDefaults: defaults
      )

      _ = try await seedingController.bootstrapClient()

      let relaunchEnvironment = HarnessMonitorEnvironment(
        values: [DaemonOwnership.environmentKey: "1"],
        homeDirectory: rememberedEnvironment.homeDirectory
      )

      #expect(
        HarnessMonitorPaths.manifestURL(using: relaunchEnvironment).path
          != HarnessMonitorPaths.manifestURL(using: rememberedEnvironment).path
      )

      let relaunchedController = DaemonController(
        environment: relaunchEnvironment,
        transportPreference: .http,
        launchAgentManager: RecordingLaunchAgentManager(state: .notRegistered),
        ownership: .external,
        sessionFactory: { _ in PreviewHarnessClient() },
        endpointProbe: { endpoint in endpoint.absoluteString == liveEndpoint },
        externalManifestDefaults: defaults
      )

      let client = try await relaunchedController.awaitManifestWarmUp(timeout: .seconds(1))

      #expect(client is PreviewHarnessClient)
    }
  }
}
