import Foundation
import OSLog

public struct SessionDiscoveryProbe: Sendable {
  public struct Preview: Sendable, Equatable {
    public let sessionId: String
    public let projectName: String
    public let title: String
    public let createdAt: Date
    public let originPath: String
    public let originReachable: Bool
    public let sessionRoot: URL
  }

  public enum Failure: Error, Sendable, Equatable {
    case notAHarnessSession(reason: String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case belongsToAnotherProject(expected: String, found: String)
    case alreadyAttached(sessionId: String)
  }

  public static let supportedSchemaVersion = 9
  private static let logger = Logger(subsystem: "io.harnessmonitor", category: "discovery")

  nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  nonisolated(unsafe) private static let isoFormatterWithFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  static func parseDate(_ value: String) -> Date {
    if let date = isoFormatterWithFractional.date(from: value) { return date }
    if let date = isoFormatter.date(from: value) { return date }
    return Date(timeIntervalSince1970: 0)
  }

  public let existingSessionIDs: Set<String>

  public init(existingSessionIDs: Set<String>) {
    self.existingSessionIDs = existingSessionIDs
  }

  public func probe(url: URL) async throws -> Preview {
    try await url.withSecurityScopeAsync { scoped in
      try Self.probeSync(at: scoped, existingSessionIDs: existingSessionIDs)
    }
  }

  static func probeSync(at url: URL, existingSessionIDs: Set<String>) throws -> Preview {
    let stateURL = url.appendingPathComponent("state.json")
    guard FileManager.default.fileExists(atPath: stateURL.path) else {
      throw Failure.notAHarnessSession(reason: "missing state.json")
    }
    let data: Data
    do {
      data = try Data(contentsOf: stateURL)
    } catch {
      throw Failure.notAHarnessSession(
        reason: "cannot read state.json: \(error.localizedDescription)"
      )
    }

    struct RawState: Decodable {
      let schemaVersion: Int
      let sessionId: String
      let projectName: String?
      let title: String?
      let createdAt: String
      let originPath: String?
      enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case projectName = "project_name"
        case title
        case createdAt = "created_at"
        case originPath = "origin_path"
      }
    }

    let raw: RawState
    do {
      raw = try JSONDecoder().decode(RawState.self, from: data)
    } catch {
      throw Failure.notAHarnessSession(
        reason: "malformed state.json: \(error.localizedDescription)"
      )
    }
    guard raw.schemaVersion == supportedSchemaVersion else {
      throw Failure.unsupportedSchemaVersion(
        found: raw.schemaVersion,
        supported: supportedSchemaVersion
      )
    }
    var isDir: ObjCBool = false
    let workspace = url.appendingPathComponent("workspace")
    guard
      FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw Failure.notAHarnessSession(reason: "missing workspace/")
    }
    let memory = url.appendingPathComponent("memory")
    guard
      FileManager.default.fileExists(atPath: memory.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw Failure.notAHarnessSession(reason: "missing memory/")
    }
    let originMarkerURL = url.appendingPathComponent(".origin")
    guard let markerData = try? Data(contentsOf: originMarkerURL),
      let rawMarker = String(data: markerData, encoding: .utf8)
    else {
      throw Failure.notAHarnessSession(reason: "missing .origin")
    }
    let marker = rawMarker.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !marker.isEmpty else {
      throw Failure.notAHarnessSession(reason: "missing .origin")
    }
    if let statedOrigin = raw.originPath, marker != statedOrigin {
      throw Failure.notAHarnessSession(reason: "origin mismatch")
    }
    let originReachable = FileManager.default.fileExists(atPath: marker)
    // Note: under App Sandbox the marker path is outside the picked URL's
    // security scope, so this check is always false for external origins.
    // Callers treat originReachable as informational only; attach still proceeds.
    if existingSessionIDs.contains(raw.sessionId) {
      throw Failure.alreadyAttached(sessionId: raw.sessionId)
    }
    let createdAt = Self.parseDate(raw.createdAt)
    logger.info("discovery probe ok: \(raw.sessionId, privacy: .public)")
    return Preview(
      sessionId: raw.sessionId,
      projectName: raw.projectName ?? "",
      title: raw.title ?? "",
      createdAt: createdAt,
      originPath: marker,
      originReachable: originReachable,
      sessionRoot: url
    )
  }
}
