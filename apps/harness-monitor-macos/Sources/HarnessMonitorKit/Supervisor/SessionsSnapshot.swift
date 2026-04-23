import CryptoKit
import Foundation

/// Immutable snapshot handed to each Monitor supervisor tick. The public field list is part of
/// the Phase 1 signature freeze. Phase 2 Unit 1 replaces the `build(from:now:)` body with a real
/// traversal + canonical hash. Rule implementations read the snapshot; they never reach into
/// `HarnessMonitorStore` directly.
public struct SessionsSnapshot: Sendable, Hashable {
  public let id: String
  public let createdAt: Date
  public let hash: String
  public let sessions: [SessionSnapshot]
  public let connection: ConnectionSnapshot

  public init(
    id: String,
    createdAt: Date,
    hash: String,
    sessions: [SessionSnapshot],
    connection: ConnectionSnapshot
  ) {
    self.id = id
    self.createdAt = createdAt
    self.hash = hash
    self.sessions = sessions
    self.connection = connection
  }

  /// An empty snapshot used by Phase 1 stubs and by Phase 2 rule tests that need a zero-state
  /// starting point. The `hash` is the empty string so idempotency keys that embed the snapshot
  /// id are deterministic across tests.
  public static let empty = Self(
    id: "",
    createdAt: Date(timeIntervalSince1970: 0),
    hash: "",
    sessions: [],
    connection: ConnectionSnapshot(kind: "disconnected", lastMessageAt: nil, reconnectAttempt: 0)
  )

  /// Walks the current `HarnessMonitorStore` state, builds a canonical `SessionsSnapshot`, and
  /// stamps it with a SHA-256 hash that deliberately excludes `id` and `createdAt` so two ticks
  /// produced from the same store state hash-compare equal.
  @MainActor
  public static func build(
    from store: HarnessMonitorStore,
    now: Date
  ) -> Self {
    let sessions = buildSessions(store: store, now: now)
    let connection = ConnectionSnapshot.from(store.connectionState)
    let hash = canonicalHash(sessions: sessions, connection: connection)
    return Self(
      id: UUID().uuidString,
      createdAt: now,
      hash: hash,
      sessions: sessions,
      connection: connection
    )
  }

  @MainActor
  private static func buildSessions(
    store: HarnessMonitorStore,
    now: Date
  ) -> [SessionSnapshot] {
    let summaries = store.sessionIndex.sessions
    let selected = store.selectedSession
    return summaries.map { summary in
      if let selected, selected.session.sessionId == summary.sessionId {
        return SessionSnapshot.from(detail: selected, summary: summary, now: now)
      }
      return SessionSnapshot.from(summary: summary)
    }
  }

  private static func canonicalHash(
    sessions: [SessionSnapshot],
    connection: ConnectionSnapshot
  ) -> String {
    let payload = SessionsCanonicalPayload(
      sessions: sessions.map(SessionCanonicalPayload.init(session:)),
      connection: connection
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(payload) else {
      return ""
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Canonical encoding that feeds the SHA-256 hash. Deliberately narrower than the public
/// `SessionsSnapshot` surface:
/// - `id` and `createdAt` are excluded so two ticks built from the same store state hash-match.
/// - `idleSeconds` is excluded because it is derived from `now` and would make the hash drift
///   between ticks that observe identical store state.
/// `lastActivityAt` stays in the payload because it is a pure store-state timestamp.
private struct SessionsCanonicalPayload: Codable {
  let sessions: [SessionCanonicalPayload]
  let connection: ConnectionSnapshot
}

private struct SessionCanonicalPayload: Codable {
  let id: String
  let title: String?
  let agents: [AgentCanonicalPayload]
  let tasks: [TaskSnapshot]
  let timelineDensityLastMinute: Int
  let observerIssues: [ObserverIssueSnapshot]
  let pendingCodexApprovals: [CodexApprovalSnapshot]

  init(session: SessionSnapshot) {
    id = session.id
    title = session.title
    agents = session.agents.map(AgentCanonicalPayload.init(agent:))
    tasks = session.tasks
    timelineDensityLastMinute = session.timelineDensityLastMinute
    observerIssues = session.observerIssues
    pendingCodexApprovals = session.pendingCodexApprovals
  }
}

private struct AgentCanonicalPayload: Codable {
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

public struct SessionSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let title: String?
  public let agents: [AgentSnapshot]
  public let tasks: [TaskSnapshot]
  public let timelineDensityLastMinute: Int
  public let observerIssues: [ObserverIssueSnapshot]
  public let pendingCodexApprovals: [CodexApprovalSnapshot]

  public init(
    id: String,
    title: String?,
    agents: [AgentSnapshot],
    tasks: [TaskSnapshot],
    timelineDensityLastMinute: Int,
    observerIssues: [ObserverIssueSnapshot],
    pendingCodexApprovals: [CodexApprovalSnapshot]
  ) {
    self.id = id
    self.title = title
    self.agents = agents
    self.tasks = tasks
    self.timelineDensityLastMinute = timelineDensityLastMinute
    self.observerIssues = observerIssues
    self.pendingCodexApprovals = pendingCodexApprovals
  }

  /// Builds a detail-backed snapshot for the session the user currently has selected.
  @MainActor
  fileprivate static func from(
    detail: SessionDetail,
    summary: SessionSummary,
    now: Date
  ) -> SessionSnapshot {
    let agents = detail.agents.map { AgentSnapshot.from(registration: $0, now: now) }
    let tasks = detail.tasks.map(TaskSnapshot.from(workItem:))
    let observerIssues =
      detail.observer?.openIssues?.map(ObserverIssueSnapshot.from(summary:)) ?? []
    return SessionSnapshot(
      id: summary.sessionId,
      title: summary.title,
      agents: agents,
      tasks: tasks,
      timelineDensityLastMinute: 0,
      observerIssues: observerIssues,
      pendingCodexApprovals: []
    )
  }

  /// Builds a summary-only snapshot for sessions the store knows about but has not hydrated yet.
  /// Rules that need agent/task detail must select the session first; this shape still lets the
  /// tick loop reason about session counts and titles.
  fileprivate static func from(summary: SessionSummary) -> SessionSnapshot {
    SessionSnapshot(
      id: summary.sessionId,
      title: summary.title,
      agents: [],
      tasks: [],
      timelineDensityLastMinute: 0,
      observerIssues: [],
      pendingCodexApprovals: []
    )
  }
}

public struct AgentSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let runtime: String
  public let statusRaw: String
  public let lastActivityAt: Date?
  public let idleSeconds: Int?
  public let currentTaskID: String?

  public init(
    id: String,
    runtime: String,
    statusRaw: String,
    lastActivityAt: Date?,
    idleSeconds: Int?,
    currentTaskID: String?
  ) {
    self.id = id
    self.runtime = runtime
    self.statusRaw = statusRaw
    self.lastActivityAt = lastActivityAt
    self.idleSeconds = idleSeconds
    self.currentTaskID = currentTaskID
  }

  @MainActor
  fileprivate static func from(registration: AgentRegistration, now: Date) -> AgentSnapshot {
    let lastActivityAt = registration.lastActivityAt.flatMap(SessionsSnapshotDateParser.parse)
    let idleSeconds = lastActivityAt.map { max(0, Int(now.timeIntervalSince($0).rounded())) }
    return AgentSnapshot(
      id: registration.agentId,
      runtime: registration.runtime,
      statusRaw: registration.status.rawValue,
      lastActivityAt: lastActivityAt,
      idleSeconds: idleSeconds,
      currentTaskID: registration.currentTaskId
    )
  }
}

public struct TaskSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let statusRaw: String
  public let assignedAgentID: String?
  public let createdAt: Date
  public let severityRaw: String

  public init(
    id: String,
    statusRaw: String,
    assignedAgentID: String?,
    createdAt: Date,
    severityRaw: String
  ) {
    self.id = id
    self.statusRaw = statusRaw
    self.assignedAgentID = assignedAgentID
    self.createdAt = createdAt
    self.severityRaw = severityRaw
  }

  @MainActor
  fileprivate static func from(workItem: WorkItem) -> TaskSnapshot {
    let createdAt =
      SessionsSnapshotDateParser.parse(workItem.createdAt) ?? Date(timeIntervalSince1970: 0)
    return TaskSnapshot(
      id: workItem.taskId,
      statusRaw: workItem.status.rawValue,
      assignedAgentID: workItem.assignedTo,
      createdAt: createdAt,
      severityRaw: workItem.severity.rawValue
    )
  }
}

public struct ObserverIssueSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let severityRaw: String
  public let code: String
  public let firstSeen: Date
  public let count: Int

  public init(
    id: String,
    severityRaw: String,
    code: String,
    firstSeen: Date,
    count: Int
  ) {
    self.id = id
    self.severityRaw = severityRaw
    self.code = code
    self.firstSeen = firstSeen
    self.count = count
  }

  fileprivate static func from(summary: ObserverIssueSummary) -> ObserverIssueSnapshot {
    ObserverIssueSnapshot(
      id: summary.issueId,
      severityRaw: summary.severity,
      code: summary.code,
      firstSeen: Date(timeIntervalSince1970: 0),
      count: summary.occurrenceCount ?? 0
    )
  }
}

public struct CodexApprovalSnapshot: Sendable, Hashable, Codable {
  public let id: String
  public let agentID: String
  public let title: String
  public let detail: String
  public let receivedAt: Date

  public init(
    id: String,
    agentID: String,
    title: String,
    detail: String,
    receivedAt: Date
  ) {
    self.id = id
    self.agentID = agentID
    self.title = title
    self.detail = detail
    self.receivedAt = receivedAt
  }
}

public struct ConnectionSnapshot: Sendable, Hashable, Codable {
  public let kind: String
  public let lastMessageAt: Date?
  public let reconnectAttempt: Int

  public init(kind: String, lastMessageAt: Date?, reconnectAttempt: Int) {
    self.kind = kind
    self.lastMessageAt = lastMessageAt
    self.reconnectAttempt = reconnectAttempt
  }

  fileprivate static func from(_ state: HarnessMonitorStore.ConnectionState) -> ConnectionSnapshot {
    let kind: String
    switch state {
    case .idle:
      kind = "disconnected"
    case .connecting:
      kind = "connecting"
    case .online:
      kind = "sse"
    case .offline:
      kind = "offline"
    }
    return ConnectionSnapshot(kind: kind, lastMessageAt: nil, reconnectAttempt: 0)
  }
}

/// Shared ISO-8601 parser for the snapshot builder. Parses both the extended
/// (`yyyy-MM-ddTHH:mm:ss.SSS±HH:MM`) and basic (`yyyy-MM-ddTHH:mm:ssZ`) variants the daemon
/// emits so idle-seconds math stays accurate regardless of which serializer ran upstream.
/// Cached on `@MainActor` because the supervisor builds snapshots from the main actor and
/// `ISO8601DateFormatter` is not `Sendable`.
@MainActor
private enum SessionsSnapshotDateParser {
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
