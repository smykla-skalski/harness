import Darwin
import Foundation

public struct ManagedLaunchAgentOwner: Codable, Equatable, Sendable {
  /// `1` is the legacy schema (pid + executablePath + registeredAt).
  /// `2` adds `bootSessionUUID` so owner records cannot survive a
  /// reboot under matching pid+exec coincidence. Decoding tolerates
  /// the absent field, so a v1 marker on disk loads with
  /// `bootSessionUUID == nil` (and the decision function then
  /// classifies it as cross-boot-stale once F1 lands in production).
  public static let currentVersion = 2

  public let version: Int
  public let pid: Int32
  public let executablePath: String
  public let registeredAt: Date
  public let bootSessionUUID: String?

  public init(
    pid: Int32,
    executablePath: String,
    registeredAt: Date,
    bootSessionUUID: String? = nil
  ) {
    self.version = bootSessionUUID == nil ? 1 : Self.currentVersion
    self.pid = pid
    self.executablePath = executablePath
    self.registeredAt = registeredAt
    self.bootSessionUUID = bootSessionUUID
  }

  public init(
    version: Int,
    pid: Int32,
    executablePath: String,
    registeredAt: Date,
    bootSessionUUID: String? = nil
  ) {
    self.version = version
    self.pid = pid
    self.executablePath = executablePath
    self.registeredAt = registeredAt
    self.bootSessionUUID = bootSessionUUID
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

/// Returns the current boot's session UUID (`kern.bootsessionuuid`)
/// or `nil` if the syscall fails. The UUID changes on every boot,
/// so an owner marker that survives a reboot will not match the
/// current value and gets classified as `.staleOwnership`.
public typealias BootSessionUUIDProbe = @Sendable () -> String?

/// Captured ownership read used as an impureim-sandwich payload:
/// gather the impure marker read once at the warm-up entry, then
/// thread the immutable snapshot through pure decision callers so
/// the predicate that decides "should we refresh" sees the same
/// ownership state the refresh itself would observe absent any
/// sibling-mid-flight write. The flock-protected refresh function
/// re-reads ownership inside its critical section regardless; the
/// snapshot's job is temporal coherence within a single warm-up
/// entry, not concurrent atomicity.
public struct OwnerSnapshot: Equatable, Sendable {
  public let owner: ManagedLaunchAgentOwner?
  public let ownership: ManagedLaunchAgentOwnership

  public init(owner: ManagedLaunchAgentOwner?, ownership: ManagedLaunchAgentOwnership) {
    self.owner = owner
    self.ownership = ownership
  }
}

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
  ///
  /// The `currentBootSessionUUID` argument carries the current
  /// `kern.bootsessionuuid`. When supplied, the decision rejects any
  /// owner whose recorded `bootSessionUUID` does not match (or is
  /// absent — a v1 schema marker that survived a reboot we cannot
  /// distinguish from the current one). A `nil` value means the
  /// caller could not read the sysctl, so the boot-axis check is
  /// skipped and the existing pid/exec corroboration carries the
  /// load.
  static func decideManagedLaunchAgentOwnership(
    owner: ManagedLaunchAgentOwner?,
    selfPid: Int32,
    liveness: (Int32) -> ProcessLiveness,
    currentBootSessionUUID: String? = nil
  ) -> ManagedLaunchAgentOwnership {
    guard let owner else {
      return .unowned
    }
    if owner.pid == selfPid {
      return .ownedBySelf
    }
    if let currentBootSessionUUID {
      guard let ownerBootSessionUUID = owner.bootSessionUUID else {
        // v1 marker (no boot UUID) seen by a v2-aware reader; we
        // cannot prove it was written this boot, so reclaim it
        // rather than trust a stranger's pid.
        return .staleOwnership(owner)
      }
      if ownerBootSessionUUID != currentBootSessionUUID {
        return .staleOwnership(owner)
      }
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

  /// Default boot-session-UUID probe via `sysctlbyname`. Returns
  /// `nil` if the syscall fails or returns an empty buffer; callers
  /// then fall through to the pid/exec corroboration without
  /// rejecting on the boot axis.
  public static let defaultBootSessionUUID: BootSessionUUIDProbe = {
    var size = 0
    if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) != 0 {
      return nil
    }
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) != 0 {
      return nil
    }
    let bytes: [UInt8] = buffer.prefix(size).map { UInt8(bitPattern: $0) }
    let raw = String(bytes: bytes, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    guard let raw, raw.isEmpty == false else { return nil }
    return raw
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
      registeredAt: Date(),
      bootSessionUUID: bootSessionUUID()
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
      liveness: processLiveness,
      currentBootSessionUUID: bootSessionUUID()
    )
  }

  /// Capture the current ownership read once and bundle it with the
  /// raw owner record as a value type. Callers thread the snapshot
  /// through pure helpers so a single warm-up entry sees a coherent
  /// ownership across multiple predicate calls.
  func currentOwnerSnapshot() -> OwnerSnapshot {
    let owner = loadManagedLaunchAgentOwner()
    let ownership = Self.decideManagedLaunchAgentOwnership(
      owner: owner,
      selfPid: getpid(),
      liveness: processLiveness,
      currentBootSessionUUID: bootSessionUUID()
    )
    return OwnerSnapshot(owner: owner, ownership: ownership)
  }
}
