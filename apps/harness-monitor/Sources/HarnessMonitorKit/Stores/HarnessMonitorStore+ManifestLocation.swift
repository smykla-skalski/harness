import Foundation

extension HarnessMonitorStore {
  public var currentManifestPath: String {
    if manifestURL == nil, !usesRemoteDaemon {
      ensureLocalManifestURL()
    }
    return manifestURL?.path ?? "Not used for remote connections"
  }

  func ensureLocalManifestURL() {
    guard manifestURL == nil else {
      return
    }
    resetLocalManifestURL()
  }

  func resetLocalManifestURL() {
    manifestURL = HarnessMonitorPaths.manifestURLWithoutLiveDiscovery()
  }

  func adoptManifestURL(from path: String) {
    guard
      let normalizedPath = HarnessMonitorPaths.normalizedNonEmpty(path),
      (normalizedPath as NSString).isAbsolutePath
    else {
      return
    }

    let manifestURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
    guard manifestURL.lastPathComponent == "manifest.json" else {
      return
    }

    self.manifestURL = manifestURL
  }
}
