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
  case commandExpired
  case invalidCommand(String)
  case unsupportedAgentKind(String)

  var allowsCloudFallback: Bool {
    if case .serverStatus(let statusCode) = self {
      return statusCode >= 500
    }
    return false
  }
}

public struct MobileRemoteDaemonSyncClient: MobileMonitorSyncClient, Sendable {
  public var supportsCommands: Bool { access.canWrite }

  let access: MobileRemoteDaemonAccess
  let stationID: String
  private let stationName: String
  private let defaultStation: Bool
  let session: URLSession

  public init(
    access: MobileRemoteDaemonAccess,
    stationID: String,
    stationName: String,
    defaultStation: Bool,
    session: URLSession
  ) {
    self.access = access
    self.stationID = stationID
    self.stationName = stationName
    self.defaultStation = defaultStation
    self.session = session
  }

  public func fetchLatestSnapshot(
    stationID: String,
    now: Date
  ) async throws -> MobileMirrorSnapshot? {
    guard stationID == self.stationID else {
      throw MobileRemoteDaemonSyncError.stationMismatch
    }
    async let sessions = fetchSessions()
    async let taskBoardItems = fetchTaskBoardItems()
    async let reviewsSnapshot = fetchReviewsSnapshot(now: now)
    return try await makeSnapshot(
      sessions: sessions,
      taskBoardItems: taskBoardItems,
      reviewsSnapshot: reviewsSnapshot,
      now: now
    )
  }

  func authenticatedRequest(path: String) -> URLRequest {
    var request = URLRequest(url: access.endpoint.appending(path: path))
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(access.bearerToken)", forHTTPHeaderField: "Authorization")
    request.setValue(
      access.clientID,
      forHTTPHeaderField: RemoteDaemonAuthentication.clientIDHeader
    )
    return request
  }

  private func fetchSessions() async throws -> [MobileRemoteSessionWire] {
    let request = authenticatedRequest(path: "/v1/sessions")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    try validate(response)
    return try JSONDecoder().decode([MobileRemoteSessionWire].self, from: data)
  }

  func validate(_ response: HTTPURLResponse) throws {
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
    taskBoardItems: [MobileRemoteTaskBoardWire],
    reviewsSnapshot: MobileRemoteReviewsSnapshot,
    now: Date
  ) -> MobileMirrorSnapshot {
    let redactor = MobileMirrorSecretRedactor()
    let mobileSessions = sessions.map {
      $0.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    }
    let mobileTaskBoardItems = taskBoardItems.map {
      $0.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    }
    let activeSessions = sessions.filter { $0.status != "ended" }
    let sessionNeedsYouCount = sessions.count(where: { $0.metrics.awaitingReviewAgentCount > 0 })
    let needsYouCount =
      sessionNeedsYouCount
      + mobileTaskBoardItems.count(where: \.needsYou)
      + reviewsSnapshot.reviews.count(where: \.needsYou)
    let station = MobileStationSummary(
      id: stationID,
      displayName: stationName,
      state: .online,
      lastSeenAt: now,
      activeSessionCount: activeSessions.count,
      needsYouCount: needsYouCount,
      commandQueueCount: 0,
      defaultStation: defaultStation
    )
    return MobileMirrorSnapshot(
      revision: 0,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [station],
      attention: reviewsSnapshot.attention,
      sessions: mobileSessions,
      reviews: reviewsSnapshot.reviews,
      taskBoardItems: mobileTaskBoardItems,
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

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileSessionSummary {
    MobileSessionSummary(
      id: sessionID,
      stationID: stationID,
      projectName: redactor.redact(projectName),
      title: title.isEmpty ? "(untitled)" : redactor.redact(title),
      branch: redactor.redact(branchRef),
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

enum MobileRemoteSessionDate {
  private static let fractional =
    Date.ISO8601FormatStyle().year().month().day()
    .timeZone(separator: .omitted)
    .time(includingFractionalSeconds: true)
  private static let standard = Date.ISO8601FormatStyle()

  static func parse(_ value: String) -> Date? {
    (try? fractional.parse(value)) ?? (try? standard.parse(value))
  }
}

private enum MobileRemoteSessionSummaryText {
  static func make(metrics: MobileRemoteSessionMetricsWire) -> String {
    "\(metrics.activeAgentCount) active agents, "
      + "\(metrics.awaitingReviewAgentCount) awaiting review"
  }
}
