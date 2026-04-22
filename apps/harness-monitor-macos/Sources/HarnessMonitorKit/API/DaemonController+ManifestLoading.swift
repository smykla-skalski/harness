import Foundation

extension DaemonController {
  private struct DaemonListeningEvent: Sendable {
    let endpoint: String
    let recordedAt: String
  }

  private static let daemonListeningEventPrefix = "daemon listening on "
  private static let daemonEventTailBytes: UInt64 = 64 * 1024

  func daemonConnection(from manifest: DaemonManifest) throws -> HarnessMonitorConnection {
    let endpoint = try endpointURL(from: manifest.endpoint)
    let token = try loadToken(path: manifest.tokenPath)
    return HarnessMonitorConnection(endpoint: endpoint, token: token)
  }

  func loadManifest() throws -> DaemonManifest {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestMissing
    }

    guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestUnreadable
    }

    let manifest = try makeDecoder().decode(DaemonManifest.self, from: data)
    let resolvedManifest = recoverManifestEndpointIfNeeded(manifest)
    let manifestFilePath = manifestURL.path
    let pid = resolvedManifest.pid
    HarnessMonitorLogger.lifecycle.trace(
      "Loaded daemon manifest from \(manifestFilePath, privacy: .public) for pid \(pid, privacy: .public)"
    )
    return resolvedManifest
  }

  func loadToken(path: String) throws -> String {
    let tokenURL = try validatedTokenURL(from: path)
    let token = try String(contentsOf: tokenURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    HarnessMonitorLogger.lifecycle.trace(
      "Loaded daemon auth token from \(tokenURL.path, privacy: .public)"
    )
    return token
  }

  func endpointURL(from value: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    guard ownership != .managed || Self.isTrustedManagedEndpoint(url) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon endpoints must use loopback http(s): \(value)"
      )
    }
    return url
  }

  private func recoverManifestEndpointIfNeeded(_ manifest: DaemonManifest) -> DaemonManifest {
    guard let event = latestDaemonListeningEvent(),
      shouldRecoverManifestEndpoint(manifest, with: event)
    else {
      return manifest
    }

    HarnessMonitorLogger.lifecycle.notice(
      """
      Recovered daemon endpoint from events log \
      \(manifest.endpoint, privacy: .public) -> \
      \(event.endpoint, privacy: .public)
      """
    )
    return DaemonManifest(
      version: manifest.version,
      pid: manifest.pid,
      endpoint: event.endpoint,
      startedAt: event.recordedAt,
      tokenPath: manifest.tokenPath,
      sandboxed: manifest.sandboxed,
      hostBridge: manifest.hostBridge,
      revision: manifest.revision,
      updatedAt: event.recordedAt,
      binaryStamp: manifest.binaryStamp
    )
  }

  private func shouldRecoverManifestEndpoint(
    _ manifest: DaemonManifest,
    with event: DaemonListeningEvent
  ) -> Bool {
    guard event.endpoint != manifest.endpoint else {
      return false
    }
    if Self.endpointNeedsRecovery(manifest.endpoint) {
      return true
    }
    let manifestTimestamp = manifest.updatedAt ?? manifest.startedAt
    return event.recordedAt > manifestTimestamp
  }

  private func latestDaemonListeningEvent() -> DaemonListeningEvent? {
    let eventsURL = HarnessMonitorPaths.daemonRoot(using: environment)
      .appendingPathComponent("events.jsonl")
    guard let handle = try? FileHandle(forReadingFrom: eventsURL) else {
      return nil
    }
    defer { try? handle.close() }

    let fileSize = (try? handle.seekToEnd()) ?? 0
    let chunkSize = min(fileSize, Self.daemonEventTailBytes)
    if chunkSize > 0 {
      try? handle.seek(toOffset: fileSize - chunkSize)
    } else {
      try? handle.seek(toOffset: 0)
    }
    guard let data = try? handle.readToEnd(), !data.isEmpty else {
      return nil
    }
    let decoder = makeDecoder()

    for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
      guard let event = try? decoder.decode(DaemonAuditEvent.self, from: Data(line)),
        let endpoint = Self.daemonListeningEndpoint(from: event.message)
      else {
        continue
      }
      return DaemonListeningEvent(endpoint: endpoint, recordedAt: event.recordedAt)
    }
    return nil
  }

  static func daemonListeningEndpoint(from message: String) -> String? {
    guard message.hasPrefix(daemonListeningEventPrefix) else {
      return nil
    }
    let endpoint = String(message.dropFirst(daemonListeningEventPrefix.count))
    return endpointNeedsRecovery(endpoint) ? nil : endpoint
  }

  static func endpointNeedsRecovery(_ endpoint: String) -> Bool {
    guard
      let url = URL(string: endpoint),
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host,
      !host.isEmpty,
      let port = url.port,
      port > 0
    else {
      return true
    }
    return false
  }

  func validatedTokenURL(from path: String) throws -> URL {
    guard (path as NSString).isAbsolutePath else {
      throw DaemonControlError.invalidManifest("token path must be absolute")
    }

    let tokenURL = URL(fileURLWithPath: path).standardizedFileURL
    let resolvedTokenURL = tokenURL.resolvingSymlinksInPath()
    guard tokenURL.path == resolvedTokenURL.path else {
      throw DaemonControlError.invalidManifest("token path must not include symlinks")
    }

    let daemonRoot = HarnessMonitorPaths.daemonRoot(using: environment)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard Self.isWithinDirectory(resolvedTokenURL, root: daemonRoot) else {
      throw DaemonControlError.invalidManifest(
        "token path must stay inside \(daemonRoot.path)"
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: resolvedTokenURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw DaemonControlError.invalidManifest("token path must reference a regular file")
    }
    guard
      let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
      ownerID == getuid()
    else {
      throw DaemonControlError.invalidManifest("token file must be owned by the current user")
    }
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard permissions & 0o077 == 0 else {
      throw DaemonControlError.invalidManifest(
        "token file permissions must not grant group or world access"
      )
    }
    return resolvedTokenURL
  }

  static func isTrustedManagedEndpoint(_ url: URL) -> Bool {
    guard
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host?.lowercased(),
      url.user == nil,
      url.password == nil
    else {
      return false
    }
    return [
      "127.0.0.1",
      "::1",
      "0:0:0:0:0:0:0:1",
      "localhost",
    ].contains(host)
  }

  static func isWithinDirectory(_ fileURL: URL, root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    let filePath = fileURL.path
    return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
  }

  func launchAgentStatus() -> LaunchAgentStatus {
    switch launchAgentManager.registrationState() {
    case .enabled:
      LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        state: "enabled"
      )
    case .requiresApproval:
      LaunchAgentStatus(
        installed: true,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        statusError: "Approval required in System Settings > General > Login Items"
      )
    case .notRegistered:
      LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon"
      )
    case .notFound:
      LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        statusError: "Bundled daemon launch agent plist was not found"
      )
    }
  }

  func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
