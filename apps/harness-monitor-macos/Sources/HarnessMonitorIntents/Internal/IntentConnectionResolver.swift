import Foundation
import HarnessMonitorKit

public enum IntentConnectionResolver {
  public static func resolve(
    environment: HarnessMonitorEnvironment = .current
  ) throws -> HarnessMonitorConnection {
    let daemonRoot = HarnessMonitorPaths.daemonRoot(using: environment)
    return try resolve(daemonRoot: daemonRoot)
  }

  public static func resolve(daemonRoot: URL) throws -> HarnessMonitorConnection {
    let manifestURL = daemonRoot.appendingPathComponent("manifest.json")
    let manifest = try readManifest(at: manifestURL)

    guard let endpointURL = URL(string: manifest.endpoint),
      let scheme = endpointURL.scheme?.lowercased(),
      scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
    else {
      throw IntentDaemonError.invalidEndpoint(value: manifest.endpoint)
    }

    let tokenURL = tokenURL(forManifest: manifest, daemonRoot: daemonRoot)
    let token = try readAuthToken(at: tokenURL)

    return HarnessMonitorConnection(endpoint: endpointURL, token: token)
  }

  static func tokenURL(forManifest manifest: DaemonManifest, daemonRoot: URL) -> URL {
    let manifestTokenPath = manifest.tokenPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !manifestTokenPath.isEmpty else {
      return daemonRoot.appendingPathComponent("auth-token")
    }
    if manifestTokenPath.hasPrefix("/") {
      return URL(fileURLWithPath: manifestTokenPath)
    }
    return daemonRoot.appendingPathComponent(manifestTokenPath)
  }

  static func readManifest(at url: URL) throws -> DaemonManifest {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw IntentDaemonError.manifestUnreadable(
        path: url.path,
        reason: error.localizedDescription
      )
    }
    do {
      return try JSONDecoder().decode(DaemonManifest.self, from: data)
    } catch {
      throw IntentDaemonError.manifestMalformed(
        path: url.path,
        reason: error.localizedDescription
      )
    }
  }

  // TODO: revisit keychain-backed token storage.
  // See memory: project-daemon-auth-token-storage-discussion-2026-05-23
  static func readAuthToken(at url: URL) throws -> String {
    let raw: String
    do {
      raw = try String(contentsOf: url, encoding: .utf8)
    } catch {
      throw IntentDaemonError.authTokenMissing(
        path: url.path,
        reason: error.localizedDescription
      )
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw IntentDaemonError.authTokenEmpty(path: url.path)
    }
    return trimmed
  }
}
