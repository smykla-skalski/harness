import Foundation
import HarnessMonitorKit
import HarnessMonitorMacRelay

@MainActor
final class HarnessMonitorMobileRelayClientProvider: @unchecked Sendable {
  private weak var store: HarnessMonitorStore?

  init(store: HarnessMonitorStore) {
    self.store = store
  }

  func client() -> (any HarnessMonitorClientProtocol)? {
    store?.apiClient
  }
}

extension HarnessMonitorApp {
  static func makeMobileRelayRuntime(
    environment: HarnessMonitorEnvironment,
    store: HarnessMonitorStore,
    runsLiveSideEffects: Bool
  ) -> MobileMacRelayRuntime? {
    guard runsLiveSideEffects else {
      return nil
    }
    guard environment.values["HARNESS_MONITOR_DISABLE_MOBILE_RELAY"] != "1" else {
      return nil
    }

    let clientProvider = HarnessMonitorMobileRelayClientProvider(store: store)
    do {
      return try MobileMacRelayRuntime(
        storageRoot: HarnessMonitorPaths.harnessRoot(using: environment)
          .appendingPathComponent("mobile-relay", isDirectory: true),
        stationName: mobileRelayStationName(),
        clientProvider: {
          await clientProvider.client()
        }
      )
    } catch {
      HarnessMonitorLogger.store.warning(
        "Failed to initialize mobile relay runtime: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func mobileRelayStationName() -> String {
    let localizedName = Host.current().localizedName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let localizedName, !localizedName.isEmpty {
      return localizedName
    }
    let hostName = ProcessInfo.processInfo.hostName
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return hostName.isEmpty ? "Mac" : hostName
  }
}
