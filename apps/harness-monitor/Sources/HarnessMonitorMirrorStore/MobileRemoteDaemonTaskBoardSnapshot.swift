import Foundation
import HarnessMonitorCore

extension MobileRemoteDaemonSyncClient {
  func fetchTaskBoardItems() async throws -> [MobileRemoteTaskBoardWire] {
    let request = authenticatedRequest(path: "/v1/task-board/items")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw MobileRemoteDaemonSyncError.invalidResponse
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
      statusTitle: Self.title(for: status),
      priority: priority,
      priorityTitle: Self.title(for: priority),
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

  private static func title(for value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
  }

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
