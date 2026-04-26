import Foundation
import Testing

@testable import HarnessMonitor
import HarnessMonitorKit

@Suite("HarnessMonitorAppConfiguration contract")
struct HarnessMonitorAppConfigurationTests {
  @MainActor
  @Test("resolve() registers MCP registry host enabled on the injected defaults store")
  func resolveMCPDefaultRegisteredOnInjectedStore() throws {
    let suiteName = "io.harnessmonitor.app-tests.mcp-contract"
    let isolated = try #require(UserDefaults(suiteName: suiteName))
    defer { isolated.removePersistentDomain(forName: suiteName) }

    let testEnv = HarnessMonitorEnvironment(
      values: [
        "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1",
        "HARNESS_MONITOR_LAUNCH_MODE": HarnessMonitorLaunchMode.preview.rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    _ = HarnessMonitorAppConfiguration.resolve(
      defaults: isolated,
      baseEnvironment: testEnv
    )

    let value = isolated.object(
      forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    ) as? Bool
    #expect(value == true)
  }
}
