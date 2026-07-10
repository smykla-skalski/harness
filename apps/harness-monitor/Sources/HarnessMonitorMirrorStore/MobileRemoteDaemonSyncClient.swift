import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto

public enum MobileRemoteDaemonSyncError: Error, Equatable, Sendable {
  case invalidResponse
  case stationMismatch
  case unauthorized
  case forbidden
  case serverStatus(Int)
  case commandsUnavailable

  var allowsCloudFallback: Bool {
    if case .serverStatus(let statusCode) = self {
      return statusCode >= 500
    }
    return false
  }
}

public struct MobileRemoteDaemonSyncClient: MobileMonitorSyncClient, Sendable {
  public let supportsCommands = false

  private let access: MobileRemoteDaemonAccess
  private let stationID: String
  private let stationName: String
  private let session: URLSession

  public init(
    access: MobileRemoteDaemonAccess,
    stationID: String,
    stationName: String,
    session: URLSession
  ) {
    self.access = access
    self.stationID = stationID
    self.stationName = stationName
    self.session = session
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    guard stationID == self.stationID else {
      throw MobileRemoteDaemonSyncError.stationMismatch
    }
    var request = URLRequest(url: access.endpoint.appending(path: "/v1/sessions"))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(access.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(
      access.clientID,
      forHTTPHeaderField: RemoteDaemonAuthentication.clientIDHeader
    )
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    let sessions = try JSONDecoder().decode([MobileRemoteSessionWire].self, from: data)
    return makeSnapshot(sessions: sessions, now: now)
  }

  public func queueCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileQueuedCommand {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  public func cancelCommand(
    _ command: MobileCommandRecord,
    currentRevision: Int64,
    now: Date
  ) async throws -> MobileCommandReceipt {
    throw MobileRemoteDaemonSyncError.commandsUnavailable
  }

  private func validate(_ response: HTTPURLResponse) throws {
    switch response.statusCode {
    case 200..<300:
      return
    case 401:
      throw MobileRemoteDaemonSyncError.unauthorized
    case 403:
      throw MobileRemoteDaemonSyncError.forbidden
    default:
      throw MobileRemoteDaemonSyncError.serverStatus(response.statusCode)
    }
  }

  private func makeSnapshot(
    sessions: [MobileRemoteSessionWire],
    now: Date
  ) -> MobileMirrorSnapshot {
    let mobileSessions = sessions.map { $0.mobileSummary(stationID: stationID, now: now) }
    let activeSessions = sessions.filter { $0.status != "ended" }
    let needsYouCount = sessions.reduce(0) { count, session in
      count + session.metrics.awaitingReviewAgentCount
    }
    let station = MobileStationSummary(
      id: stationID,
      displayName: stationName,
      state: .online,
      lastSeenAt: now,
      activeSessionCount: activeSessions.count,
      needsYouCount: needsYouCount,
      commandQueueCount: 0,
      defaultStation: true
    )
    let revision = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
    return MobileMirrorSnapshot(
      revision: revision,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [station],
      attention: [],
      sessions: mobileSessions,
      reviews: [],
      taskBoardItems: [],
      commands: [],
      trustedDevices: []
    )
  }
}

private struct MobileRemoteSessionWire: Decodable, Sendable {
  var projectName: String
  var sessionID: String
  var title: String
  var branchRef: String
  var status: String
  var updatedAt: String
  var lastActivityAt: String?
  var metrics: MobileRemoteSessionMetricsWire

  func mobileSummary(stationID: String, now: Date) -> MobileSessionSummary {
    MobileSessionSummary(
      id: sessionID,
      stationID: stationID,
      projectName: projectName,
      title: title.isEmpty ? "(untitled)" : title,
      branch: branchRef,
      status: MobileRemoteSessionStatus.title(for: status),
      activeAgentCount: metrics.activeAgentCount,
      blockedAgentCount: metrics.awaitingReviewAgentCount,
      lastActivityAt: MobileRemoteSessionDate.parse(lastActivityAt ?? updatedAt) ?? now,
      summary: MobileRemoteSessionSummaryText.make(metrics: metrics)
    )
  }

  enum CodingKeys: String, CodingKey {
    case projectName = "project_name"
    case sessionID = "session_id"
    case title
    case branchRef = "branch_ref"
    case status
    case updatedAt = "updated_at"
    case lastActivityAt = "last_activity_at"
    case metrics
  }
}

private struct MobileRemoteSessionMetricsWire: Decodable, Sendable {
  var activeAgentCount: Int
  var awaitingReviewAgentCount: Int

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activeAgentCount = try container.decodeIfPresent(Int.self, forKey: .activeAgentCount) ?? 0
    awaitingReviewAgentCount =
      try container.decodeIfPresent(Int.self, forKey: .awaitingReviewAgentCount) ?? 0
  }

  enum CodingKeys: String, CodingKey {
    case activeAgentCount = "active_agent_count"
    case awaitingReviewAgentCount = "awaiting_review_agent_count"
  }
}

private enum MobileRemoteSessionStatus {
  static func title(for status: String) -> String {
    switch status {
    case "awaiting_leader": "Awaiting leader"
    case "active": "Active"
    case "paused": "Paused"
    case "leaderless_degraded": "Leaderless degraded"
    case "ended": "Ended"
    default: status.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}

private enum MobileRemoteSessionDate {
  static func parse(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

private enum MobileRemoteSessionSummaryText {
  static func make(metrics: MobileRemoteSessionMetricsWire) -> String {
    "\(metrics.activeAgentCount) active agents, "
      + "\(metrics.awaitingReviewAgentCount) awaiting review"
  }
}
