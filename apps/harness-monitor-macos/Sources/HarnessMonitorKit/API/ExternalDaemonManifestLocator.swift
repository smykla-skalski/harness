import Foundation

final class ExternalDaemonManifestLocator: @unchecked Sendable {
  private enum DefaultsKey {
    static let rememberedManifestPath =
      "HarnessMonitor.ExternalDaemon.RememberedManifestPath"
  }

  private let defaults: UserDefaults
  private let environment: HarnessMonitorEnvironment
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
    self.environment = environment
    self.configuredManifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    self.shouldRememberLiveManifest = ownership == .external
    // Cross-lane manifest re-discovery applies to both ownership modes when
    // the app's runtime env has no lane override. The managed daemon plist
    // bakes `HARNESS_DAEMON_DATA_HOME` from the build env, so the daemon
    // writes to a lane path that the lane-agnostic IDE Run scheme cannot
    // resolve at store init — the daemon hasn't spawned yet, so cross-lane
    // discovery falls back to the non-lane base path. Allow re-resolution
    // during warm-up so the locator picks up the lane path once the daemon
    // writes its manifest there.
    self.shouldConsultRememberedManifest =
      HarnessMonitorPaths.configuredDataHomeRoot(using: environment) == nil
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
    var manifestURLs: [URL] = []
    appendCandidate(manifestURL, to: &manifestURLs)
    appendCandidate(rememberedManifestURL, to: &manifestURLs)
    appendCandidate(configuredManifestURL, to: &manifestURLs)
    return manifestURLs
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

  func refreshDiscoveredManifestURLIfNeeded() -> URL? {
    guard shouldConsultRememberedManifest else {
      return nil
    }

    let discoveredManifestURL = HarnessMonitorPaths.manifestURL(using: environment)
      .standardizedFileURL
    return lock.withLock {
      guard activeManifestURL != discoveredManifestURL else {
        return nil
      }
      activeManifestURL = discoveredManifestURL
      return discoveredManifestURL
    }
  }

  private var rememberedManifestURL: URL? {
    // Gate on `shouldRememberLiveManifest` (external-only) rather than
    // `shouldConsultRememberedManifest` so managed mode doesn't read a path
    // that only external writers populate. The UserDefaults key is shared but
    // semantically external-only.
    guard shouldRememberLiveManifest, shouldConsultRememberedManifest else {
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

  private func appendCandidate(_ manifestURL: URL?, to manifestURLs: inout [URL]) {
    guard let manifestURL else {
      return
    }

    let standardizedManifestURL = manifestURL.standardizedFileURL
    guard manifestURLs.contains(standardizedManifestURL) == false else {
      return
    }
    manifestURLs.append(standardizedManifestURL)
  }
}

protocol ExternalManifestLocationRefreshing: Sendable {
  func refreshExternalManifestLocation() async -> URL?
}

extension DaemonController: ExternalManifestLocationRefreshing {
  func refreshExternalManifestLocation() async -> URL? {
    let locator = externalManifestLocator
    return await Task.detached(priority: .utility) {
      locator.refreshDiscoveredManifestURLIfNeeded()
    }.value
  }
}
