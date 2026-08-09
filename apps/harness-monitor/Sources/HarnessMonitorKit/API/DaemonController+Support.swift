import Darwin
import Foundation
import ServiceManagement

public enum DaemonLaunchAgentRegistrationState: Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

public protocol DaemonLaunchAgentManaging: Sendable {
  func registrationState() -> DaemonLaunchAgentRegistrationState
  func register() throws
  func unregister() throws
}

public struct ServiceManagementDaemonLaunchAgentManager: DaemonLaunchAgentManaging {
  private let plistName: String

  public init(plistName: String = HarnessMonitorPaths.launchAgentPlistName) {
    self.plistName = plistName
  }

  public func registrationState() -> DaemonLaunchAgentRegistrationState {
    switch service.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  public func register() throws {
    try service.register()
  }

  public func unregister() throws {
    try service.unregister()
  }

  private var service: SMAppService {
    SMAppService.agent(plistName: plistName)
  }
}

/// One-shot cleanup of old SMAppService plists. The current sandbox-safe
/// layout uses an app-group-child service name; earlier builds used
/// `io.harnessmonitor.daemon.managed` and pre-coexistence builds used
/// `io.harnessmonitor.daemon`. We unregister them before the current service
/// is inspected so an upgrade cannot leave two automation daemons running.
public enum LegacyManagedLaunchAgentCleanup {
  public static let completedNamesDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.CompletedNames"
  static let attemptCountsDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.AttemptCounts"
  static let strategyVersionDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.StrategyVersion"
  static let strategyVersion = 2
  static let maximumAttempts = 3
  private static let lock = NSLock()
  nonisolated(unsafe) private static var didAttempt = false

  /// Runs once per process. Subsequent calls are no-ops. Within the first
  /// call, also skips any legacy plist name already recorded in `defaults`.
  public static func runOnce(
    defaults: UserDefaults = .standard,
    managerFactory: (String) -> any DaemonLaunchAgentManaging = {
      ServiceManagementDaemonLaunchAgentManager(plistName: $0)
    }
  ) {
    lock.lock()
    let alreadyAttempted = didAttempt
    didAttempt = true
    lock.unlock()
    guard !alreadyAttempted else { return }

    let currentName = HarnessMonitorPaths.launchAgentPlistName
    let usesCurrentStrategy =
      defaults.integer(forKey: strategyVersionDefaultsKey) == strategyVersion
    var completedNames =
      usesCurrentStrategy
      ? Set(defaults.stringArray(forKey: completedNamesDefaultsKey) ?? [])
      : []
    var attemptCounts =
      usesCurrentStrategy
      ? defaults.dictionary(forKey: attemptCountsDefaultsKey) as? [String: Int] ?? [:]
      : [:]
    let pendingNames = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter {
        $0 != currentName
          && !completedNames.contains($0)
          && attemptCounts[$0, default: 0] < maximumAttempts
      }
    guard pendingNames.isEmpty == false else {
      defaults.set(strategyVersion, forKey: strategyVersionDefaultsKey)
      return
    }

    for legacyName in pendingNames {
      let legacyService = managerFactory(legacyName)
      let state = legacyService.registrationState()
      HarnessMonitorLogger.lifecycle.info(
        """
        Legacy SMAppService cleanup: legacy_plist=\(legacyName, privacy: .public) \
        current_plist=\(currentName, privacy: .public) \
        status=\(String(describing: state), privacy: .public)
        """
      )
      let completed =
        state == .notRegistered
        || attemptUnregister(legacyService, name: legacyName)
      if completed {
        completedNames.insert(legacyName)
        attemptCounts.removeValue(forKey: legacyName)
      } else {
        attemptCounts[legacyName, default: 0] += 1
      }
    }

    defaults.set(completedNames.sorted(), forKey: completedNamesDefaultsKey)
    defaults.set(attemptCounts, forKey: attemptCountsDefaultsKey)
    defaults.set(strategyVersion, forKey: strategyVersionDefaultsKey)
  }

  /// Test-only escape hatch: clears the once-guard so a unit test can verify
  /// the runOnce path more than once in the same process.
  public static func resetForTests() {
    lock.lock()
    didAttempt = false
    lock.unlock()
  }

  private static func attemptUnregister(
    _ service: any DaemonLaunchAgentManaging,
    name: String
  ) -> Bool {
    do {
      try service.unregister()
      HarnessMonitorLogger.lifecycle.info(
        "Auto-unregistered legacy SMAppService plist \(name, privacy: .public)"
      )
      return true
    } catch {
      HarnessMonitorLogger.lifecycle.notice(
        """
        Could not unregister legacy SMAppService plist \(name, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
      return false
    }
  }
}

public enum DaemonControlError: Error, LocalizedError, Equatable {
  case harnessBinaryNotFound
  case manifestMissing
  case manifestUnreadable
  case invalidManifest(String)
  case managedDaemonVersionMismatch(expected: String, actual: String)
  case daemonOffline
  case daemonDidNotStart
  case externalDaemonOffline(manifestPath: String)
  case externalDaemonManifestStale(manifestPath: String)
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .harnessBinaryNotFound:
      return "Unable to locate the bundled harness daemon helper"
    case .manifestMissing:
      return "The harness daemon manifest is missing"
    case .manifestUnreadable:
      return "The harness daemon manifest could not be read"
    case .invalidManifest(let message):
      return "The harness daemon manifest failed trust validation: \(message)"
    case .managedDaemonVersionMismatch(let expected, let actual):
      return
        "The managed daemon is running version \(actual), but this app bundle expects \(expected)"
    case .daemonOffline:
      return "The harness daemon is offline. Start the daemon to load live sessions"
    case .daemonDidNotStart:
      return "The harness daemon did not become healthy before the timeout"
    case .externalDaemonOffline:
      return "Background helper is not running. Start it to load live sessions"
    case .externalDaemonManifestStale:
      return "Background helper stopped unexpectedly. Restart it to reconnect"
    case .commandFailed(let message):
      return message
    }
  }
}

public enum TransportPreference: Sendable {
  case auto
  case webSocket
  case http
}

enum ManagedStaleManifestObservation {
  case freshSignature
  case withinGrace
  case expired
}

struct ManagedStaleManifestTracker {
  private var signature: String?
  private var firstObservedAt: ContinuousClock.Instant?

  mutating func reset() {
    signature = nil
    firstObservedAt = nil
  }

  mutating func observe(
    signature: String,
    now: ContinuousClock.Instant,
    gracePeriod: Duration
  ) -> ManagedStaleManifestObservation {
    if self.signature != signature {
      self.signature = signature
      firstObservedAt = now
      return .freshSignature
    }

    guard let firstObservedAt else {
      self.firstObservedAt = now
      return .freshSignature
    }

    return now - firstObservedAt >= gracePeriod ? .expired : .withinGrace
  }
}

public struct ManagedLaunchAgentBundleStamp: Codable, Equatable, Sendable {
  let helperPath: String
  let deviceIdentifier: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeIntervalSince1970: Double
  let launchAgentPlistPath: String?
  let launchAgentPlistDeviceIdentifier: UInt64?
  let launchAgentPlistInode: UInt64?
  let launchAgentPlistFileSize: UInt64?
  let launchAgentPlistModifiedAtSeconds: Double?

  public init(
    helperPath: String,
    deviceIdentifier: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeIntervalSince1970: Double,
    launchAgentPlistPath: String? = nil,
    launchAgentPlistDeviceIdentifier: UInt64? = nil,
    launchAgentPlistInode: UInt64? = nil,
    launchAgentPlistFileSize: UInt64? = nil,
    launchAgentPlistModifiedAtSeconds: Double? = nil
  ) {
    self.helperPath = helperPath
    self.deviceIdentifier = deviceIdentifier
    self.inode = inode
    self.fileSize = fileSize
    self.modificationTimeIntervalSince1970 = modificationTimeIntervalSince1970
    self.launchAgentPlistPath = launchAgentPlistPath
    self.launchAgentPlistDeviceIdentifier = launchAgentPlistDeviceIdentifier
    self.launchAgentPlistInode = launchAgentPlistInode
    self.launchAgentPlistFileSize = launchAgentPlistFileSize
    self.launchAgentPlistModifiedAtSeconds = launchAgentPlistModifiedAtSeconds
  }

  init(helperURL: URL, launchAgentPlistURL: URL? = nil) throws {
    guard let helperMetadata = Self.fileMetadata(at: helperURL) else {
      throw DaemonControlError.harnessBinaryNotFound
    }
    let launchAgentMetadata = launchAgentPlistURL.flatMap(Self.fileMetadata)
    let launchAgentPlistPath =
      launchAgentMetadata == nil ? nil : launchAgentPlistURL?.path

    self.init(
      helperPath: helperURL.path,
      deviceIdentifier: helperMetadata.deviceIdentifier,
      inode: helperMetadata.inode,
      fileSize: helperMetadata.fileSize,
      modificationTimeIntervalSince1970: helperMetadata.modificationTimeIntervalSince1970,
      launchAgentPlistPath: launchAgentPlistPath,
      launchAgentPlistDeviceIdentifier: launchAgentMetadata?.deviceIdentifier,
      launchAgentPlistInode: launchAgentMetadata?.inode,
      launchAgentPlistFileSize: launchAgentMetadata?.fileSize,
      launchAgentPlistModifiedAtSeconds: launchAgentMetadata?.modificationTimeIntervalSince1970
    )
  }

  func matchesPublishedDaemonBinaryStamp(_ stamp: DaemonBinaryStamp?) -> Bool {
    guard let stamp else {
      return false
    }
    return helperPath == stamp.helperPath
      && deviceIdentifier == stamp.deviceIdentifier
      && inode == stamp.inode
      && fileSize == stamp.fileSize
      && modificationTimeIntervalSince1970 == stamp.modificationTimeIntervalSince1970
  }

  private struct FileMetadata: Sendable {
    let deviceIdentifier: UInt64
    let inode: UInt64
    let fileSize: UInt64
    let modificationTimeIntervalSince1970: Double
  }

  private static func fileMetadata(
    at url: URL
  ) -> FileMetadata? {
    var fileStatus = stat()
    guard url.path.withCString({ stat($0, &fileStatus) }) == 0 else {
      return nil
    }
    return FileMetadata(
      deviceIdentifier: UInt64(fileStatus.st_dev),
      inode: UInt64(fileStatus.st_ino),
      fileSize: UInt64(fileStatus.st_size),
      modificationTimeIntervalSince1970:
        Double(fileStatus.st_mtimespec.tv_sec)
        + (Double(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000)
    )
  }
}

extension DaemonBinaryStamp {
  var managedLaunchAgentBundleStamp: ManagedLaunchAgentBundleStamp {
    ManagedLaunchAgentBundleStamp(
      helperPath: helperPath,
      deviceIdentifier: deviceIdentifier,
      inode: inode,
      fileSize: fileSize,
      modificationTimeIntervalSince1970: modificationTimeIntervalSince1970
    )
  }
}

extension DaemonStatusReport {
  func replacingLaunchAgentStatus(_ launchAgent: LaunchAgentStatus) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: manifest,
      launchAgent: launchAgent,
      projectCount: projectCount,
      worktreeCount: worktreeCount,
      sessionCount: sessionCount,
      diagnostics: diagnostics
    )
  }
}
