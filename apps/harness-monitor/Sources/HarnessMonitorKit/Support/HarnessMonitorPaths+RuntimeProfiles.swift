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
    // External-daemon launches are unsandboxed and deliberately omit the
    // app-group entitlement; using the deterministic home-relative path avoids
    // container/preference probes that are only valid for sandboxed app targets.
    guard DaemonOwnership(environment: environment) == .managed else {
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

  static func resolvedRuntimeLane(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    if let explicitLane = sanitizeRuntimeLane(
      environment.values[HarnessMonitorRuntimeLane.environmentKey]
    ) {
      return explicitLane
    }

    if let inferredFromDataHome = inferRuntimeLane(
      fromPath: environment.values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]
    ) {
      return inferredFromDataHome
    }

    return nil
  }

  static func runtimeLaneBaseRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    guard let lane = resolvedRuntimeLane(using: environment) else {
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
        HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
        isDirectory: true
      )
      .appendingPathComponent(lane, isDirectory: true)
  }

  static func commandEnvironmentEntries(
    using environment: HarnessMonitorEnvironment
  ) -> [(String, String)] {
    var entries: [(String, String)] = []

    if let appGroupIdentifier = normalizedAppGroupIdentifier(using: environment) {
      entries.append((HarnessMonitorAppGroup.environmentKey, appGroupIdentifier))
    }

    if let runtimeLane = resolvedRuntimeLane(using: environment) {
      entries.append((HarnessMonitorRuntimeLane.environmentKey, runtimeLane))
    }

    if let commandDataHomeRoot = commandDataHomeRoot(using: environment) {
      entries.append(
        (HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey, commandDataHomeRoot.path))
    }

    if let codexBridgePort = resolvedCodexBridgePortString(using: environment) {
      entries.append((HarnessMonitorRuntimeLane.codexWSPortEnvironmentKey, codexBridgePort))
    }

    return entries
  }

  static func commandDataHomeRoot(
    using environment: HarnessMonitorEnvironment
  ) -> URL? {
    if let configuredRoot = configuredDataHomeRoot(using: environment) {
      return configuredRoot
    }
    return runtimeLaneBaseRoot(using: environment)
  }

  static func resolvedCodexBridgePortString(
    using environment: HarnessMonitorEnvironment
  ) -> String? {
    if let explicitPort = normalizedNonEmpty(
      environment.values[HarnessMonitorRuntimeLane.codexWSPortEnvironmentKey]
    ) {
      return explicitPort
    }

    guard let lane = resolvedRuntimeLane(using: environment) else {
      return nil
    }
    return String(derivedCodexBridgePort(for: lane))
  }

  static func derivedCodexBridgePort(for lane: String) -> Int {
    if let cached = DerivedCodexBridgePortCache.lookup(lane) {
      return cached
    }
    let digest = SHA256.hash(data: Data(lane.utf8))
    let prefix = digest.prefix(4).reduce(0) { partial, byte in
      (partial << 8) | Int(byte)
    }
    let port =
      HarnessMonitorRuntimeLane.codexWSPortBase
      + (prefix % HarnessMonitorRuntimeLane.codexWSPortSpan)
    DerivedCodexBridgePortCache.store(lane, port: port)
    return port
  }

  static func inferRuntimeLane(fromPath rawPath: String?) -> String? {
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
      if component == HarnessMonitorRuntimeLane.dataHomeLanesDirectoryName,
        components.indices.contains(index + 1)
      {
        return sanitizeRuntimeLane(components[index + 1])
      }
    }

    return nil
  }

  static func sanitizeRuntimeLane(_ rawValue: String?) -> String? {
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

private enum DerivedCodexBridgePortCache {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var entries: [String: Int] = [:]

  static func lookup(_ lane: String) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return entries[lane]
  }

  static func store(_ lane: String, port: Int) {
    lock.lock()
    defer { lock.unlock() }
    entries[lane] = port
  }
}
