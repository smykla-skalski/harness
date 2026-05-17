import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension HarnessMonitorPaths {
  /// Pick a data-home root by probing for a daemon whose ownership-scoped
  /// manifest pid is alive.
  ///
  /// Used by the Xcode IDE Run path, where the user's shell env never reaches
  /// the app and the scheme is intentionally lane-agnostic. When an explicit
  /// lane env is set (`HARNESS_MONITOR_RUNTIME_LANE` /
  /// `HARNESS_DAEMON_DATA_HOME`), the caller short-circuits before reaching
  /// this resolver.
  ///
  /// Probe order:
  /// 1. Group container root (`<container>/harness/daemon/<ownership>/manifest.json`).
  /// 2. Lane manifests under
  ///    `<container>/runtime-lanes/*/harness/daemon/<ownership>/manifest.json`.
  ///
  /// The newest live manifest by `started_at` wins. Returns the data-home
  /// root (the parent of the `harness/` subtree) so callers can reuse the
  /// existing path-composition helpers.
  static func discoverLiveDaemonRoot(
    ownership: DaemonOwnership,
    using environment: HarnessMonitorEnvironment,
    fileManager: FileManager = .default,
    pidIsLive: (Int32) -> Bool = HarnessMonitorPaths.defaultPidIsLive,
    now: Date = Date()
  ) -> URL? {
    let containerRoot = appGroupContainerCandidate(using: environment)
    guard let containerRoot else { return nil }

    var candidates: [LiveDaemonCandidate] = []
    if let rootCandidate = liveDaemonCandidate(
      atDataHome: containerRoot,
      ownership: ownership,
      fileManager: fileManager,
      pidIsLive: pidIsLive
    ) {
      candidates.append(rootCandidate)
    }

    let lanesRoot = containerRoot.appendingPathComponent(
      HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
      isDirectory: true
    )
    let laneEntries =
      (try? fileManager.contentsOfDirectory(
        at: lanesRoot,
        includingPropertiesForKeys: nil
      )) ?? []
    for laneEntry in laneEntries {
      let values = try? laneEntry.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else { continue }
      if let candidate = liveDaemonCandidate(
        atDataHome: laneEntry,
        ownership: ownership,
        fileManager: fileManager,
        pidIsLive: pidIsLive
      ) {
        candidates.append(candidate)
      }
    }

    guard !candidates.isEmpty else { return nil }
    let chosen = candidates.max { lhs, rhs in lhs.startedAt < rhs.startedAt }
    if candidates.count > 1 {
      let pids = candidates.map { String($0.pid) }.joined(separator: ",")
      let chosenPID = chosen?.pid ?? -1
      let ownershipLabel = ownership.rawValue
      HarnessMonitorLogger.store.info(
        """
        Multiple live \(ownershipLabel, privacy: .public) daemons; picked pid \
        \(chosenPID, privacy: .public) from {\(pids, privacy: .public)}
        """
      )
    }
    _ = now
    return chosen?.dataHomeRoot
  }

  static func defaultPidIsLive(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }

  private static func appGroupContainerCandidate(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    let identifier =
      normalizedAppGroupIdentifier(using: environment)
      ?? HarnessMonitorAppGroup.identifier
    if let native = nativeAppGroupContainerURL(
      identifier: identifier,
      using: environment
    ) {
      return native
    }
    return appGroupContainerURL(identifier: identifier, using: environment)
  }

  private static func liveDaemonCandidate(
    atDataHome dataHomeRoot: URL,
    ownership: DaemonOwnership,
    fileManager: FileManager,
    pidIsLive: (Int32) -> Bool
  ) -> LiveDaemonCandidate? {
    let manifestURL =
      dataHomeRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
      .appendingPathComponent(ownership.rawValue, isDirectory: true)
      .appendingPathComponent("manifest.json")
    guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
    guard let data = try? Data(contentsOf: manifestURL) else { return nil }
    guard
      let manifest = try? JSONDecoder().decode(
        DaemonManifestProbe.self, from: data
      )
    else { return nil }
    guard pidIsLive(manifest.pid) else { return nil }
    // Defense in depth: ignore a manifest whose embedded ownership field
    // disagrees with the partition it lives in. This can only happen with
    // hand-edited state or pre-coexistence manifests that landed in the
    // wrong subdir; either way the safe answer is to skip.
    if let manifestOwnership = manifest.ownership,
      DaemonOwnership(rawValue: manifestOwnership) != ownership
    {
      return nil
    }
    return LiveDaemonCandidate(
      dataHomeRoot: dataHomeRoot,
      pid: manifest.pid,
      startedAt: manifest.startedAt ?? ""
    )
  }
}

private struct LiveDaemonCandidate {
  let dataHomeRoot: URL
  let pid: Int32
  let startedAt: String
}

private struct DaemonManifestProbe: Decodable {
  let pid: Int32
  let startedAt: String?
  let ownership: String?

  enum CodingKeys: String, CodingKey {
    case pid
    case startedAt = "started_at"
    case ownership
  }
}
