import Foundation

extension HarnessMonitorStore {
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
