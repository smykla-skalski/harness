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
    let daemonCommand = HarnessMonitorPaths.shellCommand("harness daemon dev")
    switch self {
    case .harnessBinaryNotFound:
      return "Unable to locate the bundled harness daemon helper."
    case .manifestMissing:
      return "The harness daemon manifest is missing."
    case .manifestUnreadable:
      return "The harness daemon manifest could not be read."
    case .invalidManifest(let message):
      return "The harness daemon manifest failed trust validation: \(message)"
    case .managedDaemonVersionMismatch(let expected, let actual):
      return
        "The managed daemon is running version \(actual), but this app bundle expects \(expected)."
    case .daemonOffline:
      return "The harness daemon is offline. Start the daemon to load live sessions."
    case .daemonDidNotStart:
      return "The harness daemon did not become healthy before the timeout."
    case .externalDaemonOffline(let manifestPath):
      return "External daemon not running. Start it in a terminal: `\(daemonCommand)`. "
        + "Manifest expected at \(manifestPath)."
    case .externalDaemonManifestStale(let manifestPath):
      return "Stale manifest detected at \(manifestPath). The external daemon exited "
        + "without cleanup. Restart it with `\(daemonCommand)` in a terminal."
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
  let launchAgentPlistModificationTimeIntervalSince1970: Double?

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
    launchAgentPlistModificationTimeIntervalSince1970: Double? = nil
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
    self.launchAgentPlistModificationTimeIntervalSince1970 =
      launchAgentPlistModificationTimeIntervalSince1970
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
      launchAgentPlistModificationTimeIntervalSince1970:
        launchAgentMetadata?.modificationTimeIntervalSince1970
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

  private static func fileMetadata(
    at url: URL
  ) -> (
    deviceIdentifier: UInt64,
    inode: UInt64,
    fileSize: UInt64,
    modificationTimeIntervalSince1970: Double
  )? {
    var fileStatus = stat()
    guard url.path.withCString({ stat($0, &fileStatus) }) == 0 else {
      return nil
    }
    return (
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
