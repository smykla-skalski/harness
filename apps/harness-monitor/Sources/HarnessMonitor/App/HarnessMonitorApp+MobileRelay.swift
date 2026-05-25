import Foundation
import HarnessMonitorKit
import HarnessMonitorMacRelay

@MainActor
final class HarnessMonitorMobileRelayClientProvider: @unchecked Sendable {
  private weak var store: HarnessMonitorStore?

  init(store: HarnessMonitorStore) {
    self.store = store
  }

  func client() async -> (any HarnessMonitorClientProtocol)? {
    guard let store else {
      return nil
    }
    do {
      return try await store.clientForMobileRelay()
    } catch {
      HarnessMonitorLogger.store.warning(
        "Mobile relay could not open daemon client: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  func invalidateBackgroundClient(reason: String) async {
    guard let store else {
      return
    }
    await store.invalidateMobileRelayBackgroundClient(reason: reason)
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
        },
        clientFailureHandler: { reason in
          await clientProvider.invalidateBackgroundClient(reason: reason)
        },
        pairingEndpoint: MobileRelayPairingEndpointDefaults.endpoint(environment: environment)
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

enum MobileRelayPairingEndpointDefaults {
  static let environmentKey = "HARNESS_MONITOR_MOBILE_PAIRING_ENDPOINT"
  static let storageKey = "HarnessMonitorMobilePairingEndpoint"
  static let defaultValue = "https://pair.smykla.com/"

  static func endpoint(
    environment: HarnessMonitorEnvironment,
    defaults: UserDefaults = .standard
  ) -> URL? {
    if let environmentValue = environment.values[environmentKey] {
      return endpoint(from: environmentValue)
    }
    return endpoint(from: defaults.string(forKey: storageKey))
  }

  static func endpoint(from value: String?) -> URL? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      url.host?.isEmpty == false
    else {
      return nil
    }
    return url
  }
}
