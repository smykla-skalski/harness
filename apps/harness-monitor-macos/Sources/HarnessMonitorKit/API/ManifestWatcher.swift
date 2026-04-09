import Foundation

/// Watches the daemon manifest file for endpoint changes using
/// `DispatchSource` file system events. When the daemon restarts on a
/// new port, the watcher fires within milliseconds of the new manifest
/// being written, enabling sub-second reconnection.
///
/// Monitors the daemon *directory* (not the file) because the daemon
/// writes the manifest via atomic tmp-file rename, which replaces the
/// inode. Directory-level events catch renames reliably.
final class ManifestWatcher: @unchecked Sendable {
  private var source: DispatchSourceFileSystemObject?
  private var fileDescriptor: Int32 = -1
  private let directoryPath: String
  private let manifestPath: String
  private var lastEndpoint: String
  private let onChange: @Sendable () -> Void
  private let decoder: JSONDecoder

  init(
    environment: HarnessMonitorEnvironment = .current,
    currentEndpoint: String,
    onChange: @escaping @Sendable () -> Void
  ) {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    self.directoryPath = manifestURL.deletingLastPathComponent().path
    self.manifestPath = manifestURL.path
    self.lastEndpoint = currentEndpoint
    self.onChange = onChange
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.decoder = decoder
  }

  func start() {
    stop()
    let path = directoryPath
    fileDescriptor = open(path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      HarnessMonitorLogger.lifecycle.warning(
        "ManifestWatcher: failed to open directory \(path, privacy: .public)"
      )
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .attrib],
      queue: .global(qos: .utility)
    )
    source.setEventHandler { [weak self] in
      self?.handleDirectoryChange()
    }
    source.setCancelHandler { [weak self] in
      guard let self, self.fileDescriptor >= 0 else { return }
      close(self.fileDescriptor)
      self.fileDescriptor = -1
    }
    source.resume()
    self.source = source
    HarnessMonitorLogger.lifecycle.info(
      "ManifestWatcher: watching \(path, privacy: .public)"
    )
  }

  func stop() {
    source?.cancel()
    source = nil
  }

  private func handleDirectoryChange() {
    guard let data = FileManager.default.contents(atPath: manifestPath) else {
      return
    }
    guard let manifest = try? decoder.decode(ManifestSnapshot.self, from: data) else {
      return
    }
    guard manifest.endpoint != lastEndpoint else {
      return
    }
    let oldEndpoint = lastEndpoint
    lastEndpoint = manifest.endpoint
    HarnessMonitorLogger.lifecycle.info(
      """
      ManifestWatcher: endpoint changed \
      from \(oldEndpoint, privacy: .public) \
      to \(manifest.endpoint, privacy: .public)
      """
    )
    onChange()
  }
}

private struct ManifestSnapshot: Decodable {
  let endpoint: String
}
