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
      let storageRoot = MobileRelayStorageResolver.prepareStorageRoot(environment: environment)
      return try MobileMacRelayRuntime(
        storageRoot: storageRoot,
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

enum MobileRelayStorageResolver {
  private static let stationIdentityFileName = "station-identity.json"
  private static let trustedDevicesFileName = "trusted-mobile-devices.json"

  static func prepareStorageRoot(
    environment: HarnessMonitorEnvironment,
    fileManager: FileManager = .default
  ) -> URL {
    let stableRoot = storageRoot(environment: environment)
    migrateTrustedLaneStateIfNeeded(
      to: stableRoot,
      from: legacyStorageRoots(environment: environment, fileManager: fileManager),
      fileManager: fileManager
    )
    return stableRoot
  }

  static func storageRoot(environment: HarnessMonitorEnvironment) -> URL {
    HarnessMonitorPaths.appGroupHarnessRoot(using: environment)
      .appendingPathComponent("mobile-relay", isDirectory: true)
  }

  static func legacyStorageRoots(
    environment: HarnessMonitorEnvironment,
    fileManager: FileManager = .default
  ) -> [URL] {
    var roots: [URL] = []
    let stableRoot = storageRoot(environment: environment)
    appendUnique(
      HarnessMonitorPaths.harnessRoot(using: environment)
        .appendingPathComponent("mobile-relay", isDirectory: true),
      to: &roots,
      excluding: stableRoot
    )

    let lanesRoot =
      HarnessMonitorPaths.appGroupHarnessRoot(using: environment)
      .deletingLastPathComponent()
      .appendingPathComponent(
        HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
        isDirectory: true
      )
    guard
      let laneDirectories = try? fileManager.contentsOfDirectory(
        at: lanesRoot,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return roots
    }

    for laneDirectory in laneDirectories {
      appendUnique(
        laneDirectory
          .appendingPathComponent("harness", isDirectory: true)
          .appendingPathComponent("mobile-relay", isDirectory: true),
        to: &roots,
        excluding: stableRoot
      )
    }
    return roots
  }

  private static func migrateTrustedLaneStateIfNeeded(
    to stableRoot: URL,
    from legacyRoots: [URL],
    fileManager: FileManager
  ) {
    let stableCandidate = MobileRelayStorageCandidate(root: stableRoot, fileManager: fileManager)
    guard !stableCandidate.hasUsablePairingState else {
      return
    }
    guard
      let candidate =
        legacyRoots
        .map({ MobileRelayStorageCandidate(root: $0, fileManager: fileManager) })
        .filter(\.hasUsablePairingState)
        .max(by: MobileRelayStorageCandidate.prefersRightCandidate)
    else {
      return
    }

    do {
      try fileManager.createDirectory(
        at: stableRoot,
        withIntermediateDirectories: true
      )
      try replaceFile(
        stationIdentityFileName,
        from: candidate.root,
        to: stableRoot,
        fileManager: fileManager
      )
      try replaceFile(
        trustedDevicesFileName,
        from: candidate.root,
        to: stableRoot,
        fileManager: fileManager
      )
      HarnessMonitorLogger.store.info(
        "Migrated mobile relay pairing state from runtime lane storage."
      )
    } catch {
      HarnessMonitorLogger.store.warning(
        "Could not migrate mobile relay pairing state: \(String(describing: error), privacy: .public)"
      )
    }
  }

  private static func replaceFile(
    _ fileName: String,
    from sourceRoot: URL,
    to destinationRoot: URL,
    fileManager: FileManager
  ) throws {
    let source = sourceRoot.appendingPathComponent(fileName)
    let destination = destinationRoot.appendingPathComponent(fileName)
    guard fileManager.fileExists(atPath: source.path) else {
      return
    }
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
  }

  private static func appendUnique(
    _ root: URL,
    to roots: inout [URL],
    excluding excludedRoot: URL
  ) {
    let standardizedRoot = root.standardizedFileURL
    guard standardizedRoot != excludedRoot.standardizedFileURL,
      !roots.contains(standardizedRoot)
    else {
      return
    }
    roots.append(standardizedRoot)
  }
}

private struct MobileRelayStorageCandidate {
  var root: URL
  var stationID: String?
  var trustedDeviceCount: Int
  var trustedDeviceStationIDs: Set<String>
  var latestModificationDate: Date
  var hasStationIdentity: Bool

  init(root: URL, fileManager: FileManager) {
    self.root = root
    let stationIdentityURL = root.appendingPathComponent("station-identity.json")
    let trustedDevicesURL = root.appendingPathComponent("trusted-mobile-devices.json")
    hasStationIdentity = fileManager.fileExists(atPath: stationIdentityURL.path)
    stationID = Self.stationID(at: stationIdentityURL)
    let trustedDevices = Self.trustedDevices(at: trustedDevicesURL)
    self.trustedDeviceStationIDs = trustedDevices.stationIDs
    trustedDeviceCount = trustedDevices.count
    latestModificationDate =
      [
        Self.modificationDate(at: stationIdentityURL),
        Self.modificationDate(at: trustedDevicesURL),
      ]
      .compactMap(\.self)
      .max() ?? .distantPast
  }

  var hasUsablePairingState: Bool {
    guard hasStationIdentity, let stationID, trustedDeviceCount > 0 else {
      return false
    }
    return trustedDeviceStationIDs == [stationID]
  }

  static func prefersRightCandidate(
    lhs: Self,
    rhs: Self
  ) -> Bool {
    if lhs.trustedDeviceCount != rhs.trustedDeviceCount {
      return lhs.trustedDeviceCount < rhs.trustedDeviceCount
    }
    return lhs.latestModificationDate < rhs.latestModificationDate
  }

  private static func stationID(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return identity["stationID"] as? String
  }

  private static func trustedDevices(at url: URL) -> (count: Int, stationIDs: Set<String>) {
    guard let data = try? Data(contentsOf: url),
      let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return (0, [])
    }
    return (
      devices.count,
      Set(devices.compactMap { $0["stationID"] as? String })
    )
  }

  private static func modificationDate(at url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
