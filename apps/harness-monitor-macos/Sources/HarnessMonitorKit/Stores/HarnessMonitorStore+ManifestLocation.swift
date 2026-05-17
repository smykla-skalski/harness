import Foundation

extension HarnessMonitorStore {
  public var currentManifestPath: String {
    manifestURL.path
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
