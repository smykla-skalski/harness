import Foundation

extension HarnessMonitorStore {
  func startManifestWatcher() {
    stopManifestWatcher()
    guard maintainsLiveDaemonObservation else {
      return
    }
    let daemonRoot = manifestURL.deletingLastPathComponent()
    // The dispatch source opens the daemon directory; create it first so the
    // watcher still starts when the dev daemon has never run yet. This is
    // required for external daemon mode where the app may launch before the
    // terminal daemon exists.
    try? FileManager.default.createDirectory(
      at: daemonRoot,
      withIntermediateDirectories: true
    )
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let currentEndpoint: String
    let currentStartedAt: String?
    let currentRevision: UInt64
    if let data = FileManager.default.contents(atPath: manifestURL.path),
      let manifest = try? decoder.decode(DaemonManifest.self, from: data)
    {
      currentEndpoint = manifest.endpoint
      currentStartedAt = manifest.startedAt
      currentRevision = manifest.revision
    } else {
      // Manifest missing or undecodable; start with an empty sentinel so the
      // first valid manifest write triggers reconnect.
      currentEndpoint = ""
      currentStartedAt = nil
      currentRevision = 0
    }
    let watcher = ManifestWatcher(
      manifestURL: manifestURL,
      currentEndpoint: currentEndpoint,
      currentStartedAt: currentStartedAt,
      currentRevision: currentRevision
    ) { [weak self] change in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch change {
        case .connectionChange:
          self.appendConnectionEvent(
            kind: .reconnecting,
            detail: "Daemon manifest changed, re-bootstrapping"
          )
          await self.reconnect()
        case .inPlaceUpdate(let manifest):
          self.applyManifestRevision(manifest)
        }
      }
    }
    manifestWatcher = watcher
    watcher.start()
    refreshExternalManifestDiscoveryTask()
  }

  func stopManifestWatcher() {
    stopExternalManifestDiscoveryTask()
    manifestWatcher?.stop()
    manifestWatcher = nil
  }

  func refreshExternalManifestDiscoveryTask() {
    guard manifestWatcher != nil,
      maintainsLiveDaemonObservation,
      daemonOwnership == .external
    else {
      stopExternalManifestDiscoveryTask()
      return
    }
    if case .online = connectionState {
      stopExternalManifestDiscoveryTask()
      return
    }
    guard externalManifestDiscoveryTask == nil,
      let refresher = daemonController as? any ExternalManifestLocationRefreshing
    else {
      return
    }

    externalManifestDiscoveryTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        guard self.manifestWatcher != nil else {
          return
        }
        if case .online = self.connectionState {
          return
        }

        if let refreshedManifestURL = await refresher.refreshExternalManifestLocation() {
          self.adoptManifestURL(from: refreshedManifestURL.path)
          self.appendConnectionEvent(
            kind: .reconnecting,
            detail: "Discovered live external daemon manifest, re-bootstrapping"
          )
          await self.reconnect()
          return
        }

        do {
          try await Task.sleep(for: self.externalManifestDiscoveryInterval)
        } catch {
          return
        }
      }
    }
  }

  func stopExternalManifestDiscoveryTask() {
    externalManifestDiscoveryTask?.cancel()
    externalManifestDiscoveryTask = nil
  }
}
