import Foundation

/// Immutable snapshot handed to each Monitor supervisor tick. The public field list is part of
/// the Phase 1 signature freeze. Phase 2 worker 1 replaces the `build(from:now:)` body with a
/// real traversal + canonical hash; Phase 1 returns an empty snapshot so the project compiles
/// and the tick loop has something to hand to rules.
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
  public static let empty = SessionsSnapshot(
    id: "",
    createdAt: Date(timeIntervalSince1970: 0),
    hash: "",
    sessions: [],
    connection: ConnectionSnapshot(kind: "disconnected", lastMessageAt: nil, reconnectAttempt: 0)
  )

  /// Phase 1 stub. Phase 2 worker 1 (`SessionsSnapshot builder`) replaces this with a real
  /// traversal of `HarnessMonitorStore` slices, canonical JSON encoding, and a SHA-256 hash.
  public static func build(
    from store: HarnessMonitorStore,
    now: Date
  ) -> SessionsSnapshot {
    _ = store
    return SessionsSnapshot(
      id: UUID().uuidString,
      createdAt: now,
      hash: "",
      sessions: [],
      connection: ConnectionSnapshot(
        kind: "disconnected",
        lastMessageAt: nil,
        reconnectAttempt: 0
      )
    )
  }
}

public struct SessionSnapshot: Sendable, Hashable {
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
}

public struct AgentSnapshot: Sendable, Hashable {
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
}

public struct TaskSnapshot: Sendable, Hashable {
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
}

public struct ObserverIssueSnapshot: Sendable, Hashable {
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
}

public struct CodexApprovalSnapshot: Sendable, Hashable {
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

public struct ConnectionSnapshot: Sendable, Hashable {
  public let kind: String
  public let lastMessageAt: Date?
  public let reconnectAttempt: Int

  public init(kind: String, lastMessageAt: Date?, reconnectAttempt: Int) {
    self.kind = kind
    self.lastMessageAt = lastMessageAt
    self.reconnectAttempt = reconnectAttempt
  }
}
