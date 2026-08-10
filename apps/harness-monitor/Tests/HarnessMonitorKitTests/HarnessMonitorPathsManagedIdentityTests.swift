import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor managed identity paths")
struct HarnessMonitorPathsManagedIdentityTests {
  @Test("Bundled managed daemon identity remains one coherent runtime lane")
  func bundledManagedDaemonIdentityRemainsCoherent() throws {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorPathsTests-\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let dataHome = "/tmp/harness-monitor/runtime-lanes/lane-a"
    let info: [String: Any] = [
      "CFBundleIdentifier": "io.harnessmonitor.tests.paths",
      "CFBundleName": "HarnessMonitorPathsTests",
      "CFBundlePackageType": "APPL",
      "HarnessMonitorManagedLaunchAgentLabel":
        "Q498EB36N4.io.harnessmonitor.agent-lane-a",
      "HarnessMonitorManagedDaemonDataHome": dataHome,
      "HarnessMonitorManagedDaemonRuntimeLane": "lane-a",
      "HarnessMonitorManagedDaemonCodexWSPort": "4812",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
    let environment = HarnessMonitorEnvironment(
      values: [:],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
      bundleURL: bundleURL
    )

    #expect(
      HarnessMonitorPaths.launchAgentLabel(using: environment)
        == "Q498EB36N4.io.harnessmonitor.agent-lane-a"
    )
    #expect(HarnessMonitorPaths.runtimeLane(using: environment) == "lane-a")
    #expect(HarnessMonitorPaths.codexBridgePort(using: environment) == 4_812)
    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == "\(dataHome)/harness/daemon/managed"
    )
  }

  @Test("Managed bundle identity stays coherent while external mode honors explicit profile")
  func managedBundleIdentityOutranksConflictingRuntimeProfile() throws {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorPathsTests-\(UUID().uuidString).app")
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "io.harnessmonitor.tests.paths",
      "CFBundleName": "HarnessMonitorPathsTests",
      "CFBundlePackageType": "APPL",
      "HarnessMonitorManagedLaunchAgentLabel":
        "Q498EB36N4.io.harnessmonitor.agent-lane-a",
      "HarnessMonitorManagedDaemonDataHome": "/tmp/runtime-lanes/lane-a",
      "HarnessMonitorManagedDaemonRuntimeLane": "lane-a",
      "HarnessMonitorManagedDaemonCodexWSPort": "4812",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

    let launchAgentsURL =
      contentsURL
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("LaunchAgents", isDirectory: true)
    try FileManager.default.createDirectory(
      at: launchAgentsURL,
      withIntermediateDirectories: true
    )
    try Data().write(
      to: launchAgentsURL.appendingPathComponent(
        "Q498EB36N4.io.harnessmonitor.agent-lane-a.plist"
      )
    )
    let explicitDataHome = "/tmp/runtime-lanes/lane-b"
    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorRuntimeLane.environmentKey: "lane-b",
        "XDG_DATA_HOME": explicitDataHome,
      ],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
      bundleURL: bundleURL
    )

    #expect(HarnessMonitorPaths.runtimeLane(using: environment) == "lane-a")
    #expect(
      HarnessMonitorPaths.launchAgentLabel(using: environment)
        == "Q498EB36N4.io.harnessmonitor.agent-lane-a"
    )
    #expect(HarnessMonitorPaths.codexBridgePort(using: environment) == 4_812)
    #expect(
      HarnessMonitorPaths.daemonRoot(using: environment).path
        == "/tmp/runtime-lanes/lane-a/harness/daemon/managed"
    )
    #expect(
      FileManager.default.fileExists(
        atPath: bundleURL.appendingPathComponent(
          HarnessMonitorPaths.launchAgentBundleRelativePath(using: environment)
        ).path
      )
    )

    let externalEnvironment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorRuntimeLane.environmentKey: "lane-b",
        "XDG_DATA_HOME": explicitDataHome,
        DaemonOwnership.environmentKey: "external",
      ],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true),
      bundleURL: bundleURL
    )
    #expect(HarnessMonitorPaths.runtimeLane(using: externalEnvironment) == "lane-b")
    #expect(
      HarnessMonitorPaths.codexBridgePort(using: externalEnvironment)
        == HarnessMonitorPaths.derivedCodexBridgePort(for: "lane-b")
    )
    #expect(
      HarnessMonitorPaths.daemonRoot(using: externalEnvironment).path
        == "\(explicitDataHome)/harness/daemon/external"
    )
  }
}
