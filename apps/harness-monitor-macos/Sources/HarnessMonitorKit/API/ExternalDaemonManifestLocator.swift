import Foundation

final class ExternalDaemonManifestLocator: @unchecked Sendable {
  private enum DefaultsKey {
    static let rememberedManifestPath =
      "HarnessMonitor.ExternalDaemon.RememberedManifestPath"
  }

  private let defaults: UserDefaults
  private let configuredManifestURL: URL
  private let shouldConsultRememberedManifest: Bool
  private let shouldRememberLiveManifest: Bool
  private let lock = NSLock()
  private var activeManifestURL: URL

  init(
    environment: HarnessMonitorEnvironment,
    ownership: DaemonOwnership,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    self.configuredManifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    self.shouldRememberLiveManifest = ownership == .external
    self.shouldConsultRememberedManifest =
      ownership == .external
      && HarnessMonitorPaths.configuredDataHomeRoot(using: environment) == nil
      && HarnessMonitorPaths.resolvedRuntimeLane(using: environment) == nil
    self.activeManifestURL = configuredManifestURL

    if let rememberedManifestURL {
      self.activeManifestURL = rememberedManifestURL
    }
  }

  var manifestURL: URL {
    lock.withLock { activeManifestURL }
  }

  var daemonRoot: URL {
    manifestURL.deletingLastPathComponent()
  }

  func candidateManifestURLs() -> [URL] {
    guard let rememberedManifestURL else {
      return [configuredManifestURL]
    }
    guard rememberedManifestURL != configuredManifestURL else {
      return [configuredManifestURL]
    }
    return [rememberedManifestURL, configuredManifestURL]
  }

  func activate(_ manifestURL: URL) {
    lock.withLock {
      activeManifestURL = manifestURL.standardizedFileURL
    }
  }

  func rememberActiveManifestIfNeeded() {
    guard shouldRememberLiveManifest else {
      return
    }
    defaults.set(manifestURL.path, forKey: DefaultsKey.rememberedManifestPath)
  }

  private var rememberedManifestURL: URL? {
    guard shouldConsultRememberedManifest else {
      return nil
    }
    guard
      let rawValue = defaults.string(forKey: DefaultsKey.rememberedManifestPath)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty,
      (rawValue as NSString).isAbsolutePath
    else {
      return nil
    }

    let manifestURL = URL(fileURLWithPath: rawValue).standardizedFileURL
    guard manifestURL.lastPathComponent == "manifest.json" else {
      return nil
    }
    return manifestURL
  }
}
