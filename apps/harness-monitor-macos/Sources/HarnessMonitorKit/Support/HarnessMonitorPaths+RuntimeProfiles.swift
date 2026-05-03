import CryptoKit
import Foundation

extension HarnessMonitorPaths {
  static func normalizedAppGroupIdentifier(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    guard
      let value = environment.values[HarnessMonitorAppGroup.environmentKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  static func nativeAppGroupContainerURL(
    identifier: String,
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    guard !environment.isXCTestProcess else {
      return nil
    }
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: identifier
    )
  }

  static func appGroupContainerURL(
    identifier: String,
    using environment: HarnessMonitorEnvironment
  ) -> URL {
    environment.homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Group Containers", isDirectory: true)
      .appendingPathComponent(identifier, isDirectory: true)
  }

  static func configuredDataHomeRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    let daemonDataHomeValue = environment.values[
      HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let daemonDataHomeValue, !daemonDataHomeValue.isEmpty {
      return URL(fileURLWithPath: daemonDataHomeValue, isDirectory: true)
    }

    let xdgDataHomeValue = environment.values["XDG_DATA_HOME"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let xdgDataHomeValue, !xdgDataHomeValue.isEmpty {
      return URL(fileURLWithPath: xdgDataHomeValue, isDirectory: true)
    }

    return nil
  }

  static func resolvedRuntimeProfile(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    if let explicitProfile = sanitizeRuntimeProfile(
      environment.values[HarnessMonitorRuntimeProfile.environmentKey]
    ) {
      return explicitProfile
    }

    if let inferredFromDataHome = inferRuntimeProfile(
      fromPath: environment.values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]
    ) {
      return inferredFromDataHome
    }

    if let inferredFromDerivedData = inferRuntimeProfile(
      fromPath: environment.values["XCODEBUILD_DERIVED_DATA_PATH"]
    ) {
      return inferredFromDerivedData
    }

    if let bundleURL = environment.bundleURL,
      let inferredFromBundle = inferRuntimeProfile(fromPath: bundleURL.path)
    {
      return inferredFromBundle
    }

    return nil
  }

  static func runtimeProfileBaseRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    guard let profile = resolvedRuntimeProfile(using: environment) else {
      return nil
    }

    let appGroupIdentifier =
      normalizedAppGroupIdentifier(using: environment)
      ?? HarnessMonitorAppGroup.identifier
    let containerRoot =
      nativeAppGroupContainerURL(identifier: appGroupIdentifier, using: environment)
      ?? appGroupContainerURL(identifier: appGroupIdentifier, using: environment)
    return
      containerRoot
      .appendingPathComponent(
        HarnessMonitorRuntimeProfile.dataHomeProfilesDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(profile, isDirectory: true)
  }

  static func commandEnvironmentEntries(
    using environment: HarnessMonitorEnvironment
  ) -> [(String, String)] {
    var entries: [(String, String)] = []

    if let appGroupIdentifier = normalizedAppGroupIdentifier(using: environment) {
      entries.append((HarnessMonitorAppGroup.environmentKey, appGroupIdentifier))
    }

    if let runtimeProfile = resolvedRuntimeProfile(using: environment) {
      entries.append((HarnessMonitorRuntimeProfile.environmentKey, runtimeProfile))
    }

    if let commandDataHomeRoot = commandDataHomeRoot(using: environment) {
      entries.append(
        (HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey, commandDataHomeRoot.path))
    }

    if let codexBridgePort = resolvedCodexBridgePortString(using: environment) {
      entries.append((HarnessMonitorRuntimeProfile.codexWSPortEnvironmentKey, codexBridgePort))
    }

    return entries
  }

  static func commandDataHomeRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    if let configuredRoot = configuredDataHomeRoot(using: environment) {
      return configuredRoot
    }
    return runtimeProfileBaseRoot(using: environment)
  }

  static func resolvedCodexBridgePortString(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    if let explicitPort = normalizedNonEmpty(
      environment.values[HarnessMonitorRuntimeProfile.codexWSPortEnvironmentKey]
    ) {
      return explicitPort
    }

    guard let profile = resolvedRuntimeProfile(using: environment) else {
      return nil
    }
    return String(derivedCodexBridgePort(for: profile))
  }

  static func derivedCodexBridgePort(for profile: String) -> Int {
    let digest = SHA256.hash(data: Data(profile.utf8))
    let prefix = digest.prefix(4).reduce(0) { partial, byte in
      (partial << 8) | Int(byte)
    }
    return HarnessMonitorRuntimeProfile.codexWSPortBase
      + (prefix % HarnessMonitorRuntimeProfile.codexWSPortSpan)
  }

  static func inferRuntimeProfile(fromPath rawPath: String?) -> String? {
    guard let rawPath = normalizedNonEmpty(rawPath) else {
      return nil
    }

    let components = NSString(string: rawPath).standardizingPath
      .split(separator: "/")
      .map(String.init)
    guard !components.isEmpty else {
      return nil
    }

    for index in components.indices {
      let component = components[index]
      if HarnessMonitorRuntimeProfile.supportedDerivedDataRoots.contains(component),
        components.indices.contains(index + 2),
        components[index + 1] == HarnessMonitorRuntimeProfile.derivedDataProfilesDirectoryName
      {
        return sanitizeRuntimeProfile(components[index + 2])
      }

      if component == HarnessMonitorRuntimeProfile.dataHomeProfilesDirectoryName,
        components.indices.contains(index + 1)
      {
        return sanitizeRuntimeProfile(components[index + 1])
      }
    }

    return nil
  }

  static func sanitizeRuntimeProfile(_ rawValue: String?) -> String? {
    guard let trimmed = normalizedNonEmpty(rawValue) else {
      return nil
    }

    var sanitized = ""
    var previousWasDash = false
    for scalar in trimmed.lowercased().unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        sanitized.unicodeScalars.append(scalar)
        previousWasDash = false
      } else if !previousWasDash {
        sanitized.append("-")
        previousWasDash = true
      }
    }

    sanitized = String(sanitized.prefix(48))
    sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return sanitized.isEmpty ? nil : sanitized
  }

  static func normalizedNonEmpty(_ rawValue: String?) -> String? {
    guard let rawValue else {
      return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func shellEscape(_ rawValue: String) -> String {
    "'\(rawValue.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
