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

  @Test("warm-up switches from a stale root manifest to a live runtime-lane manifest")
  func warmUpSwitchesFromStaleRootManifestToLiveRuntimeLaneManifest() async throws {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("daemon-controller-cross-lane-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    let appGroupRoot = externalAppGroupRoot(homeDirectory: homeDirectory)
    let rootDaemonRoot = appGroupRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
    try FileManager.default.createDirectory(at: rootDaemonRoot, withIntermediateDirectories: true)

    let rootTokenURL = rootDaemonRoot.appendingPathComponent("auth-token")
    try writeTokenFixture(to: rootTokenURL)
    let staleRootManifestURL = rootDaemonRoot.appendingPathComponent("manifest.json")
    try writeExternalManifestFixture(
      at: staleRootManifestURL,
      pid: 999_999,
      endpoint: "http://127.0.0.1:65530",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: rootTokenURL.path
    )

    let environment = HarnessMonitorEnvironment(
      values: [
        DaemonOwnership.environmentKey: "1",
        HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier,
      ],
      homeDirectory: homeDirectory
    )
    #expect(HarnessMonitorPaths.manifestURL(using: environment).path == staleRootManifestURL.path)

    let liveEndpoint = "http://127.0.0.1:65531"
    async let laneManifestWriter: Void = withSignalIgnoringSleepProcessPID(durationSeconds: 60) {
      pid in
      try await Task.sleep(for: .milliseconds(250))
      let laneDaemonRoot = appGroupRoot
        .appendingPathComponent("runtime-lanes", isDirectory: true)
        .appendingPathComponent("late-start", isDirectory: true)
        .appendingPathComponent("harness", isDirectory: true)
        .appendingPathComponent("daemon", isDirectory: true)
      try FileManager.default.createDirectory(at: laneDaemonRoot, withIntermediateDirectories: true)

      let laneTokenURL = laneDaemonRoot.appendingPathComponent("auth-token")
      try writeTokenFixture(to: laneTokenURL)
      try writeExternalManifestFixture(
        at: laneDaemonRoot.appendingPathComponent("manifest.json"),
        pid: Int(pid),
        endpoint: liveEndpoint,
        startedAt: "2026-04-11T12:05:00Z",
        tokenPath: laneTokenURL.path
      )
    }

    let controller = DaemonController(
      environment: environment,
      transportPreference: .http,
      launchAgentManager: RecordingLaunchAgentManager(state: .notRegistered),
      ownership: .external,
      sessionFactory: { _ in PreviewHarnessClient() },
      endpointProbe: { endpoint in endpoint.absoluteString == liveEndpoint }
    )

    let client = try await controller.awaitManifestWarmUp(timeout: .seconds(2))
    try await laneManifestWriter

    #expect(client is PreviewHarnessClient)
  }
}

private func externalAppGroupRoot(homeDirectory: URL) -> URL {
  homeDirectory
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Group Containers", isDirectory: true)
    .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
}

private func writeExternalManifestFixture(
  at manifestURL: URL,
  pid: Int,
  endpoint: String,
  startedAt: String,
  tokenPath: String
) throws {
  let payload: [String: Any] = [
    "version": "19.4.1",
    "pid": pid,
    "endpoint": endpoint,
    "started_at": startedAt,
    "token_path": tokenPath,
    "sandboxed": true,
    "host_bridge": [
      "running": false,
      "socket_path": NSNull(),
      "capabilities": [:],
    ],
    "revision": 0,
  ]
  let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: manifestURL, options: .atomic)
}
