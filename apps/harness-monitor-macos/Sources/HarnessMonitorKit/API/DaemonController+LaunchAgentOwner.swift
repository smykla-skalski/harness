import Darwin
import Foundation

public struct ManagedLaunchAgentOwner: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let pid: Int32
  public let executablePath: String
  public let registeredAt: Date

  public init(pid: Int32, executablePath: String, registeredAt: Date) {
    self.version = Self.currentVersion
    self.pid = pid
    self.executablePath = executablePath
    self.registeredAt = registeredAt
  }

  public init(version: Int, pid: Int32, executablePath: String, registeredAt: Date) {
    self.version = version
    self.pid = pid
    self.executablePath = executablePath
    self.registeredAt = registeredAt
  }
}

public enum ProcessLiveness: Equatable, Sendable {
  case dead
  case alive(executablePath: String?)
}

public enum ManagedLaunchAgentOwnership: Equatable, Sendable {
  case unowned
  case ownedBySelf
  case ownedByLiveSibling(ManagedLaunchAgentOwner)
  case staleOwnership(ManagedLaunchAgentOwner)
}

public enum ManagedLaunchAgentRefreshDecision: Equatable, Sendable {
  case refreshed
  case skippedSiblingOwnsLane(ManagedLaunchAgentOwner)
  case skippedNotManagedDaemon
  /// Another Monitor process holds the daemon-root lock. We don't
  /// know which sibling, only that the lane is mid-transaction.
  /// Caller should leave its pending state queued and re-evaluate
  /// on the next warm-up entry.
  case skippedLockContended
}

public typealias ProcessLivenessProbe = @Sendable (Int32) -> ProcessLiveness

extension HarnessMonitorPaths {
  public static func managedLaunchAgentOwnerURL(
    using environment: HarnessMonitorEnvironment = .current
  ) -> URL {
    Self.daemonRoot(using: environment)
      .appendingPathComponent("managed-launch-agent-owner.json")
  }
}

extension DaemonController {
  /// Pure decision over an ownership snapshot. Loads no IO; performs no
  /// syscall. The four-case sum lets callers reclaim a stale lane
  /// (`.staleOwnership`) without conflating it with `.unowned`.
  static func decideManagedLaunchAgentOwnership(
    owner: ManagedLaunchAgentOwner?,
    selfPid: Int32,
    liveness: (Int32) -> ProcessLiveness
  ) -> ManagedLaunchAgentOwnership {
    guard let owner else {
      return .unowned
    }
    if owner.pid == selfPid {
      return .ownedBySelf
    }
    switch liveness(owner.pid) {
    case .dead:
      return .staleOwnership(owner)
    case .alive(let runningExecutablePath):
      // PID may have been recycled. If we could read the running
      // process's executable path, demand it match the recorded one;
      // any mismatch means the recorded sibling is gone and the PID is
      // now in use by an unrelated process.
      if let runningExecutablePath, runningExecutablePath != owner.executablePath {
        return .staleOwnership(owner)
      }
      return .ownedByLiveSibling(owner)
    }
  }

  /// Default Darwin liveness probe. Capture errno into a local
  /// immediately after `kill(pid, 0)` so any subsequent Foundation hop
  /// cannot perturb the read. When the process is alive, resolve the
  /// running executable path via `proc_pidpath` so the pure decision
  /// can corroborate against the recorded `executablePath`.
  public static let defaultProcessLiveness: ProcessLivenessProbe = { pid in
    let rc = kill(pid, 0)
    if rc != 0 {
      let err = errno
      if err == ESRCH {
        return .dead
      }
      // EPERM and similar still mean the process exists but we cannot
      // signal it. Fall through and try to read its image path.
    }

    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let length = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int32 in
      guard let baseAddress = bufferPtr.baseAddress else {
        return 0
      }
      return proc_pidpath(pid, baseAddress, UInt32(bufferPtr.count))
    }
    if length > 0 {
      let bytes: [UInt8] = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
      return .alive(executablePath: String(bytes: bytes, encoding: .utf8))
    }
    return .alive(executablePath: nil)
  }

  func loadManagedLaunchAgentOwner() -> ManagedLaunchAgentOwner? {
    let url = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: environment)
    guard let data = FileManager.default.contents(atPath: url.path) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(ManagedLaunchAgentOwner.self, from: data)
    } catch {
      // A corrupt or schema-skewed file is a real signal — surface it
      // so the operator can see the marker is unusable instead of
      // silently treating the lane as unowned.
      HarnessMonitorLogger.lifecycle.warning(
        "Managed launch-agent owner marker is unreadable: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  func persistCurrentManagedLaunchAgentOwner() throws {
    let url = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: environment)
    let executablePath = Bundle.main.executablePath ?? Bundle.main.bundleURL.path
    let owner = ManagedLaunchAgentOwner(
      pid: getpid(),
      executablePath: executablePath,
      registeredAt: Date()
    )
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(owner)
    try data.write(to: url, options: .atomic)
  }

  func clearManagedLaunchAgentOwner() {
    let url = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: environment)
    do {
      try FileManager.default.removeItem(at: url)
    } catch CocoaError.fileNoSuchFile {
      // Already gone; nothing to do.
    } catch {
      HarnessMonitorLogger.lifecycle.warning(
        "Failed to clear managed launch-agent owner marker: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  /// Refresh the on-disk owner record snapshot through the pure
  /// decision function. Re-evaluates per call so a sibling that exited
  /// since the last check is correctly reclassified as
  /// `.staleOwnership` (and a fresh sibling that registered since the
  /// last check is correctly classified as `.ownedByLiveSibling`).
  func currentManagedLaunchAgentOwnership() -> ManagedLaunchAgentOwnership {
    Self.decideManagedLaunchAgentOwnership(
      owner: loadManagedLaunchAgentOwner(),
      selfPid: getpid(),
      liveness: processLiveness
    )
  }
}
