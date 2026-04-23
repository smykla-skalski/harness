import Foundation

struct SessionsCanonicalPayload: Codable {
  let sessions: [SessionCanonicalPayload]
  let connection: ConnectionSnapshot
}

struct SessionCanonicalPayload: Codable {
  let id: String
  let title: String?
  let agents: [AgentCanonicalPayload]
  let tasks: [TaskSnapshot]
  let observerIssues: [ObserverIssueSnapshot]
  let pendingCodexApprovals: [CodexApprovalSnapshot]

  init(session: SessionSnapshot) {
    id = session.id
    title = session.title
    agents = session.agents.map(AgentCanonicalPayload.init(agent:))
    tasks = session.tasks
    observerIssues = session.observerIssues
    pendingCodexApprovals = session.pendingCodexApprovals
  }
}

struct AgentCanonicalPayload: Codable {
  let id: String
  let runtime: String
  let statusRaw: String
  let lastActivityAt: Date?
  let currentTaskID: String?

  init(agent: AgentSnapshot) {
    id = agent.id
    runtime = agent.runtime
    statusRaw = agent.statusRaw
    lastActivityAt = agent.lastActivityAt
    currentTaskID = agent.currentTaskID
  }
}

@MainActor
enum SessionsSnapshotDateParser {
  static func parse(_ iso: String) -> Date? {
    if let date = Self.internetDateFormatter.date(from: iso) {
      return date
    }
    if let date = Self.fractionalFormatter.date(from: iso) {
      return date
    }
    return nil
  }

  private static let internetDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  private static let fractionalFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

extension CodexApprovalSnapshot {
  @MainActor
  static func from(runs: [CodexRunSnapshot]) -> [CodexApprovalSnapshot] {
    var seen = Set<String>()
    var snapshots: [CodexApprovalSnapshot] = []

    for run in runs {
      let receivedAt =
        SessionsSnapshotDateParser.parse(run.updatedAt)
        ?? SessionsSnapshotDateParser.parse(run.createdAt)
        ?? Date(timeIntervalSince1970: 0)
      for approval in run.pendingApprovals where seen.insert(approval.approvalId).inserted {
        snapshots.append(
          CodexApprovalSnapshot(
            id: approval.approvalId,
            agentID: run.runId,
            title: approval.title,
            detail: approval.detail,
            receivedAt: receivedAt
          )
        )
      }
    }

    return snapshots.sorted { left, right in
      if left.receivedAt != right.receivedAt {
        return left.receivedAt > right.receivedAt
      }
      return left.id < right.id
    }
  }
}
