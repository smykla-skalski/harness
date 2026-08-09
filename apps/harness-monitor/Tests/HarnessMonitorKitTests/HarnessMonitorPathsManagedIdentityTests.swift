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
}
