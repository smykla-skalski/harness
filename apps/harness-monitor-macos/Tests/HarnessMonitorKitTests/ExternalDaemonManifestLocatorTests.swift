import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("ExternalDaemonManifestLocator refresh behaviour")
struct ExternalDaemonManifestLocatorTests {
  @Test(
    "refresh returns nil when no live daemon is discoverable so the watcher does not flap to the non-lane fallback"
  )
  func refreshReturnsNilWhenNoLiveDaemonIsDiscoverable() throws {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "manifest-locator-no-live-daemon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    let environment = makeGroupContainerEnvironment(homeDirectory: homeDirectory)

    let locator = ExternalDaemonManifestLocator(
      environment: environment,
      ownership: .managed,
      defaults: try throwawayDefaults()
    )

    let seededURL = locator.manifestURL

    #expect(locator.refreshDiscoveredManifestURLIfNeeded() == nil)
    #expect(locator.manifestURL == seededURL)
  }

  @Test(
    "refresh adopts the lane manifest URL once a live daemon shows up under runtime-lanes"
  )
  func refreshAdoptsLaneURLOnceLiveDaemonAppears() throws {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "manifest-locator-late-lane-daemon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    let environment = makeGroupContainerEnvironment(homeDirectory: homeDirectory)

    let locator = ExternalDaemonManifestLocator(
      environment: environment,
      ownership: .managed,
      defaults: try throwawayDefaults()
    )

    let appGroupRoot = groupContainerRoot(homeDirectory: homeDirectory)
    let laneRoot =
      appGroupRoot
      .appendingPathComponent("runtime-lanes", isDirectory: true)
      .appendingPathComponent("harness-cafef00d", isDirectory: true)
    let laneManifestURL = try writeManagedManifestFixture(
      dataHomeRoot: laneRoot,
      pid: Int32(getpid()),
      startedAt: "2026-05-17T12:00:00Z"
    )

    let refreshedURL = try #require(locator.refreshDiscoveredManifestURLIfNeeded())
    #expect(refreshedURL.standardizedFileURL == laneManifestURL.standardizedFileURL)
    #expect(locator.manifestURL.standardizedFileURL == laneManifestURL.standardizedFileURL)
  }

  @Test(
    "refresh keeps the previously-adopted lane URL while the daemon is briefly dead between restarts"
  )
  func refreshKeepsLaneURLWhileDaemonIsBrieflyDead() throws {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "manifest-locator-restart-flap-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    let environment = makeGroupContainerEnvironment(homeDirectory: homeDirectory)

    let locator = ExternalDaemonManifestLocator(
      environment: environment,
      ownership: .managed,
      defaults: try throwawayDefaults()
    )

    let appGroupRoot = groupContainerRoot(homeDirectory: homeDirectory)
    let laneRoot =
      appGroupRoot
      .appendingPathComponent("runtime-lanes", isDirectory: true)
      .appendingPathComponent("harness-cafef00d", isDirectory: true)
    let laneManifestURL = try writeManagedManifestFixture(
      dataHomeRoot: laneRoot,
      pid: Int32(getpid()),
      startedAt: "2026-05-17T12:00:00Z"
    )

    _ = locator.refreshDiscoveredManifestURLIfNeeded()
    #expect(locator.manifestURL.standardizedFileURL == laneManifestURL.standardizedFileURL)

    // Daemon dies mid-flight: rewrite the manifest with a pid that is
    // guaranteed dead so cross-lane discovery returns nil.
    try writeManagedManifestFixture(
      at: laneManifestURL,
      pid: 1,
      startedAt: "2026-05-17T12:00:00Z"
    )

    #expect(locator.refreshDiscoveredManifestURLIfNeeded() == nil)
    #expect(locator.manifestURL.standardizedFileURL == laneManifestURL.standardizedFileURL)
  }

  private func throwawayDefaults() throws -> UserDefaults {
    let suite = "ExternalDaemonManifestLocatorTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func makeGroupContainerEnvironment(homeDirectory: URL) -> HarnessMonitorEnvironment {
    HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.environmentKey: HarnessMonitorAppGroup.identifier
      ],
      homeDirectory: homeDirectory
    )
  }

  private func groupContainerRoot(homeDirectory: URL) -> URL {
    homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(HarnessMonitorAppGroup.identifier, isDirectory: true)
  }

  @discardableResult
  private func writeManagedManifestFixture(
    dataHomeRoot: URL,
    pid: Int32,
    startedAt: String
  ) throws -> URL {
    let daemonRoot =
      dataHomeRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
      .appendingPathComponent(DaemonOwnership.managed.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
    let manifestURL = daemonRoot.appendingPathComponent("manifest.json")
    try writeManagedManifestFixture(at: manifestURL, pid: pid, startedAt: startedAt)
    return manifestURL
  }

  private func writeManagedManifestFixture(
    at manifestURL: URL,
    pid: Int32,
    startedAt: String
  ) throws {
    let tokenURL = manifestURL.deletingLastPathComponent()
      .appendingPathComponent("auth-token")
    try Data("token".utf8).write(to: tokenURL, options: .atomic)
    let payload: [String: Any] = [
      "version": "19.4.1",
      "pid": Int(pid),
      "endpoint": "http://127.0.0.1:0",
      "started_at": startedAt,
      "token_path": tokenURL.path,
      "sandboxed": true,
      "ownership": DaemonOwnership.managed.rawValue,
      "host_bridge": [
        "running": false,
        "socket_path": NSNull(),
        "capabilities": [:],
      ],
      "revision": 0,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: manifestURL, options: .atomic)
  }
}
