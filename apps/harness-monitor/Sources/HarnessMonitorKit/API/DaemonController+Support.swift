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
/// `io.harnessmonitor.daemon`. We try to unregister both silently on the first
/// launch under the new layout and accept any failure.
public enum LegacyManagedLaunchAgentCleanup {
  /// UserDefaults key tracking which legacy plist names we have already
  /// attempted to evict on this machine. Once a name is in here we skip the
  /// per-launch attempt; SMAppService throws "Operation not permitted" when
  /// the plist file is absent from the bundle whether or not BTM still holds
  /// a record, so we cannot tell success from failure and one try is all the
  /// framework gives us.
  public static let completedNamesDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.CompletedNames"
  private static let lock = NSLock()
  nonisolated(unsafe) private static var didAttempt = false

  /// Runs once per process. Subsequent calls are no-ops. Within the first
  /// call, also skips any legacy plist name already recorded in `defaults`.
  public static func runOnce(defaults: UserDefaults = .standard) {
    lock.lock()
    let alreadyAttempted = didAttempt
    didAttempt = true
    lock.unlock()
    guard !alreadyAttempted else { return }

    let currentName = HarnessMonitorPaths.launchAgentPlistName
    let completedNames = Set(
      defaults.stringArray(forKey: completedNamesDefaultsKey) ?? []
    )
    let pendingNames = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != currentName && !completedNames.contains($0) }
    guard pendingNames.isEmpty == false else { return }

    for legacyName in pendingNames {
      // Attempt the unregister regardless of `SMAppService.status`. BTM may
      // still hold a disposition record for an old label, and `unregister()`
      // is the framework-owned eviction path. The marker below ensures we
      // only burn the one attempt SMAppService allows per machine.
      let legacyService = SMAppService.agent(plistName: legacyName)
      HarnessMonitorLogger.lifecycle.info(
        """
        Legacy SMAppService cleanup: legacy_plist=\(legacyName, privacy: .public) \
        current_plist=\(currentName, privacy: .public) \
        status_raw=\(String(describing: legacyService.status), privacy: .public)
        """
      )
      attemptUnregister(legacyService, name: legacyName)
    }

    let updated = completedNames.union(pendingNames)
    defaults.set(updated.sorted(), forKey: completedNamesDefaultsKey)
  }

  /// Test-only escape hatch: clears the once-guard so a unit test can verify
  /// the runOnce path more than once in the same process.
  public static func resetForTests() {
    lock.lock()
    didAttempt = false
    lock.unlock()
  }

  private static func attemptUnregister(_ service: SMAppService, name: String) {
    do {
      try service.unregister()
      HarnessMonitorLogger.lifecycle.info(
        "Auto-unregistered legacy SMAppService plist \(name, privacy: .public)"
      )
    } catch {
      HarnessMonitorLogger.lifecycle.notice(
        """
        Could not unregister legacy SMAppService plist \(name, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
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
