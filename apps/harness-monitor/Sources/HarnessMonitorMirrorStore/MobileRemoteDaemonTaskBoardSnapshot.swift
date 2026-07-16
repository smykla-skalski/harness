import Foundation
import HarnessMonitorCore

extension MobileRemoteDaemonSyncClient {
  func fetchTaskBoardItems() async throws -> [MobileRemoteTaskBoardWire] {
    let request = authenticatedRequest(path: "/v1/task-board/items")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
    guard response.statusCode != 404 else {
      return []
    }
    try validate(response)
    return try JSONDecoder().decode(MobileRemoteTaskBoardListWire.self, from: data).items
  }
}

private struct MobileRemoteTaskBoardListWire: Decodable, Sendable {
  var items: [MobileRemoteTaskBoardWire]
}

struct MobileRemoteTaskBoardWire: Decodable, Sendable {
  var id: String
  var title: String
  var body: String
  var status: String
  var priority: String
  var tags: [String]?
  var projectID: String?
  var agentMode: String
  var sessionID: String?
  var workItemID: String?
  var updatedAt: String

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileTaskBoardSummary {
    MobileTaskBoardSummary(
      id: id,
      stationID: stationID,
      title: redactor.redact(title),
      bodyPreview: bodyPreview(redactor: redactor),
      status: status,
      statusTitle: Self.statusTitle(for: status),
      priority: priority,
      priorityTitle: Self.priorityTitle(for: priority),
      tags: (tags ?? []).map(redactor.redact),
      projectID: projectID.map(redactor.redact),
      sessionID: sessionID,
      workItemID: workItemID,
      agentMode: agentMode,
      needsYou: Self.needsYouStatuses.contains(status),
      updatedAt: MobileRemoteSessionDate.parse(updatedAt) ?? now
    )
  }

  private func bodyPreview(redactor: MobileMirrorSecretRedactor) -> String {
    let redacted = redactor.redact(body.trimmingCharacters(in: .whitespacesAndNewlines))
    guard redacted.count > 180 else {
      return redacted
    }
    return "\(redacted.prefix(177))..."
  }

  private static func statusTitle(for value: String) -> String {
    statusTitles[value] ?? value
  }

  private static func priorityTitle(for value: String) -> String {
    priorityTitles[value] ?? value
  }

  private static let statusTitles = [
    "backlog": "Backlog",
    "todo": "Todo",
    "new": "New",
    "planning": "Planning",
    "agentic_review": "Agentic Review",
    "plan_review": "Plan Review",
    "needs_you": "Needs You",
    "in_progress": "In Progress",
    "testing": "Testing",
    "in_review": "In Review",
    "to_review": "To Review",
    "human_required": "Human Required",
    "failed": "Failed",
    "done": "Done",
    "blocked": "Blocked",
  ]

  private static let priorityTitles = [
    "low": "Low",
    "medium": "Medium",
    "high": "High",
    "critical": "Critical",
  ]

  private static let needsYouStatuses: Set<String> = [
    "agentic_review",
    "blocked",
    "failed",
    "human_required",
    "needs_you",
    "plan_review",
  ]

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case body
    case status
    case priority
    case tags
    case projectID = "project_id"
    case agentMode = "agent_mode"
    case sessionID = "session_id"
    case workItemID = "work_item_id"
    case updatedAt = "updated_at"
  }
}
