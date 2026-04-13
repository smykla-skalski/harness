import Foundation
import Synchronization

/// Change categories emitted by [`ManifestWatcher`]. Callers use the case
/// to decide whether the change warrants a full reconnect or a lightweight
/// in-place refresh.
enum ManifestChange: Sendable {
  /// Endpoint or started_at moved on disk. Existing daemon connections are
  /// stale - the store should reconnect.
  case connectionChange(DaemonManifest)
  /// Only the manifest revision moved (typically a host_bridge update).
  /// Existing connections are still valid, the store only needs to refresh
  /// `daemonStatus` in place.
  case inPlaceUpdate(DaemonManifest)
}

/// Serialized mutable state of the watcher. Wrapped in a `Mutex` so the
/// enclosing class can be `Sendable` without `@unchecked`.
private struct ManifestWatcherState {
  var lastEndpoint: String
  var lastStartedAt: String?
  var lastRevision: UInt64
  var source: DispatchSourceFileSystemObject?
  var fileDescriptor: Int32
}

/// Watches the daemon manifest file for changes using `DispatchSource` file
/// system events.
///
/// When the daemon restarts on a new port, the watcher fires within
/// milliseconds of the new manifest being written - enabling sub-second
/// reconnection. When the daemon rewrites the manifest in place (e.g. to
/// publish a host_bridge state change), the watcher emits a lightweight
/// `.inPlaceUpdate` so the store can refresh its slice without tearing
/// down any streams.
///
/// Monitors the daemon *directory* (not the file) because the daemon writes
/// the manifest via atomic tmp-file rename, which replaces the inode.
/// Directory-level events catch renames reliably.
///
/// ## Concurrency
///
/// The class is `Sendable`. All mutable state lives behind a single
/// `Mutex<ManifestWatcherState>` following the project's
/// `PendingRequestStore` pattern (`API/WebSocketProtocol.swift`). The
/// dispatch source event handler runs on `DispatchQueue.global(qos: .utility)`,
/// so decoding and diffing happen off MainActor. The lock is released
/// before invoking the `@Sendable` `onChange` callback, so callers can
/// safely `Task { @MainActor in ... }` without risking a lock-across-await
/// deadlock.
final class ManifestWatcher: Sendable {
  private let directoryPath: String
  private let manifestPath: String
  private let onChange: @Sendable (ManifestChange) -> Void
  private let decoder: JSONDecoder
  private let state: Mutex<ManifestWatcherState>

  init(
    environment: HarnessMonitorEnvironment = .current,
    currentEndpoint: String,
    currentStartedAt: String? = nil,
    currentRevision: UInt64 = 0,
    onChange: @escaping @Sendable (ManifestChange) -> Void
  ) {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    self.directoryPath = manifestURL.deletingLastPathComponent().path
    self.manifestPath = manifestURL.path
    self.onChange = onChange
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.decoder = decoder
    self.state = Mutex(
      ManifestWatcherState(
        lastEndpoint: currentEndpoint,
        lastStartedAt: currentStartedAt,
        lastRevision: currentRevision,
        source: nil,
        fileDescriptor: -1
      )
    )
  }

  func start() {
    stop()
    let path = directoryPath
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else {
      HarnessMonitorLogger.lifecycle.warning(
        "ManifestWatcher: failed to open directory \(path, privacy: .public)"
      )
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .attrib],
      queue: .global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      self?.handleDirectoryChange()
    }
    source.setCancelHandler { [weak self] in
      self?.closeDescriptor()
    }

    state.withLock { state in
      state.source = source
      state.fileDescriptor = descriptor
    }

    source.resume()

    HarnessMonitorLogger.lifecycle.info(
      "ManifestWatcher: watching \(path, privacy: .public)"
    )
  }

  func stop() {
    let source = state.withLock { state -> DispatchSourceFileSystemObject? in
      let existing = state.source
      state.source = nil
      return existing
    }
    source?.cancel()
  }

  /// Invoked from the dispatch source cancel handler. Closes the file
  /// descriptor held in the state and resets it to -1.
  private func closeDescriptor() {
    let descriptor = state.withLock { state -> Int32 in
      let fd = state.fileDescriptor
      state.fileDescriptor = -1
      return fd
    }
    if descriptor >= 0 {
      close(descriptor)
    }
  }

  private func handleDirectoryChange() {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: manifestPath) else {
      return
    }
    guard let data = fileManager.contents(atPath: manifestPath) else {
      HarnessMonitorLogger.lifecycle.warning(
        "ManifestWatcher: failed to read manifest \(self.manifestPath, privacy: .public)"
      )
      return
    }
    let manifest: DaemonManifest
    do {
      manifest = try decoder.decode(DaemonManifest.self, from: data)
    } catch {
      HarnessMonitorLogger.lifecycle.warning(
        """
        ManifestWatcher: failed to decode manifest \
        \(self.manifestPath, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
      return
    }

    let change: ManifestChange? = state.withLock { state -> ManifestChange? in
      let endpointChanged = manifest.endpoint != state.lastEndpoint
      let startedAtChanged = manifest.startedAt != state.lastStartedAt
      let revisionChanged = manifest.revision != state.lastRevision
      guard endpointChanged || startedAtChanged || revisionChanged else {
        return nil
      }

      let previousEndpoint = state.lastEndpoint
      let previousStartedAt = state.lastStartedAt
      let previousRevision = state.lastRevision

      state.lastEndpoint = manifest.endpoint
      state.lastStartedAt = manifest.startedAt
      state.lastRevision = manifest.revision

      if endpointChanged || startedAtChanged {
        HarnessMonitorLogger.lifecycle.info(
          """
          ManifestWatcher: connection change \
          from \(previousEndpoint, privacy: .public) \
          (\(previousStartedAt ?? "unknown", privacy: .public)) \
          to \(manifest.endpoint, privacy: .public) \
          (\(manifest.startedAt, privacy: .public))
          """
        )
        return .connectionChange(manifest)
      }

      HarnessMonitorLogger.lifecycle.info(
        """
        ManifestWatcher: in-place update revision \
        \(previousRevision, privacy: .public) -> \
        \(manifest.revision, privacy: .public)
        """
      )
      return .inPlaceUpdate(manifest)
    }

    if let change {
      onChange(change)
    }
  }
}
