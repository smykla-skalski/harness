import Foundation

public struct WorktreeSummary: Codable, Equatable, Identifiable, Sendable {
  public let checkoutId: String
  public let name: String
  public let checkoutRoot: String
  public let contextRoot: String
  public let activeSessionCount: Int
  public let totalSessionCount: Int

  public var id: String { checkoutId }

  public init(
    checkoutId: String,
    name: String,
    checkoutRoot: String,
    contextRoot: String,
    activeSessionCount: Int,
    totalSessionCount: Int
  ) {
    self.checkoutId = checkoutId
    self.name = name
    self.checkoutRoot = checkoutRoot
    self.contextRoot = contextRoot
    self.activeSessionCount = activeSessionCount
    self.totalSessionCount = totalSessionCount
  }
}

public struct ProjectSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let name: String
  public let projectDir: String?
  public let contextRoot: String
  public let activeSessionCount: Int
  public let totalSessionCount: Int
  public let worktrees: [WorktreeSummary]

  public var id: String { projectId }

  public init(
    projectId: String,
    name: String,
    projectDir: String?,
    contextRoot: String,
    activeSessionCount: Int,
    totalSessionCount: Int,
    worktrees: [WorktreeSummary] = []
  ) {
    self.projectId = projectId
    self.name = name
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.activeSessionCount = activeSessionCount
    self.totalSessionCount = totalSessionCount
    self.worktrees = worktrees
  }

  enum CodingKeys: String, CodingKey {
    case projectId, name, projectDir, contextRoot, activeSessionCount, totalSessionCount, worktrees
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      projectId: try container.decode(String.self, forKey: .projectId),
      name: try container.decode(String.self, forKey: .name),
      projectDir: try container.decodeIfPresent(String.self, forKey: .projectDir),
      contextRoot: try container.decode(String.self, forKey: .contextRoot),
      activeSessionCount: try container.decode(Int.self, forKey: .activeSessionCount),
      totalSessionCount: try container.decode(Int.self, forKey: .totalSessionCount),
      worktrees: try container.decodeIfPresent([WorktreeSummary].self, forKey: .worktrees) ?? []
    )
  }
}

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
  case active
  case paused
  case leaderlessDegraded = "leaderless_degraded"
  case ended

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .paused:
      "Paused"
    case .leaderlessDegraded:
      "Leaderless"
    case .ended:
      "Ended"
    }
  }
}

public struct SessionMetrics: Codable, Equatable, Sendable {
  public let agentCount: Int
  public let activeAgentCount: Int
  public let openTaskCount: Int
  public let inProgressTaskCount: Int
  public let blockedTaskCount: Int
  public let completedTaskCount: Int
}

public struct SessionSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let projectName: String
  public let projectDir: String?
  public let contextRoot: String
  public let sessionId: String
  public let worktreePath: String
  public let sharedPath: String
  public let originPath: String
  public let branchRef: String
  public let title: String
  public let context: String
  public let status: SessionStatus
  public let createdAt: String
  public let updatedAt: String
  public let lastActivityAt: String?
  public let leaderId: String?
  public let observeId: String?
  public let pendingLeaderTransfer: PendingLeaderTransfer?
  public let externalOrigin: String?
  public let adoptedAt: String?
  public let metrics: SessionMetrics

  public var id: String { sessionId }

  public var displayTitle: String { title.isEmpty ? "(untitled)" : title }

  public init(
    projectId: String,
    projectName: String,
    projectDir: String? = nil,
    contextRoot: String = "",
    sessionId: String,
    worktreePath: String = "",
    sharedPath: String = "",
    originPath: String = "",
    branchRef: String = "",
    title: String = "",
    context: String,
    status: SessionStatus,
    createdAt: String,
    updatedAt: String,
    lastActivityAt: String?,
    leaderId: String?,
    observeId: String?,
    pendingLeaderTransfer: PendingLeaderTransfer?,
    externalOrigin: String? = nil,
    adoptedAt: String? = nil,
    metrics: SessionMetrics
  ) {
    self.projectId = projectId
    self.projectName = projectName
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.sessionId = sessionId
    self.worktreePath = worktreePath
    self.sharedPath = sharedPath
    self.originPath = originPath
    self.branchRef = branchRef
    self.title = title
    self.context = context
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastActivityAt = lastActivityAt
    self.leaderId = leaderId
    self.observeId = observeId
    self.pendingLeaderTransfer = pendingLeaderTransfer
    self.externalOrigin = externalOrigin
    self.adoptedAt = adoptedAt
    self.metrics = metrics
  }

  /// Display name for the worktree branch, derived from `branchRef`.
  public var worktreeDisplayName: String {
    if branchRef.hasPrefix("harness/") {
      return String(branchRef.dropFirst("harness/".count))
    }
    return branchRef.isEmpty ? sessionId : branchRef
  }

  enum CodingKeys: CodingKey {
    case projectId, projectName, projectDir, contextRoot
    case sessionId, worktreePath, sharedPath, originPath, branchRef
    case title, context, status
    case createdAt, updatedAt, lastActivityAt
    case leaderId, observeId, pendingLeaderTransfer, externalOrigin, adoptedAt, metrics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      projectId: try container.decode(String.self, forKey: .projectId),
      projectName: try container.decodeIfPresent(String.self, forKey: .projectName) ?? "",
      projectDir: try container.decodeIfPresent(String.self, forKey: .projectDir),
      contextRoot: try container.decodeIfPresent(String.self, forKey: .contextRoot) ?? "",
      sessionId: try container.decode(String.self, forKey: .sessionId),
      worktreePath: try container.decodeIfPresent(String.self, forKey: .worktreePath) ?? "",
      sharedPath: try container.decodeIfPresent(String.self, forKey: .sharedPath) ?? "",
      originPath: try container.decodeIfPresent(String.self, forKey: .originPath) ?? "",
      branchRef: try container.decodeIfPresent(String.self, forKey: .branchRef) ?? "",
      title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
      context: try container.decode(String.self, forKey: .context),
      status: try container.decode(SessionStatus.self, forKey: .status),
      createdAt: try container.decode(String.self, forKey: .createdAt),
      updatedAt: try container.decode(String.self, forKey: .updatedAt),
      lastActivityAt: try container.decodeIfPresent(String.self, forKey: .lastActivityAt),
      leaderId: try container.decodeIfPresent(String.self, forKey: .leaderId),
      observeId: try container.decodeIfPresent(String.self, forKey: .observeId),
      pendingLeaderTransfer: try container.decodeIfPresent(
        PendingLeaderTransfer.self,
        forKey: .pendingLeaderTransfer
      ),
      externalOrigin: try container.decodeIfPresent(String.self, forKey: .externalOrigin),
      adoptedAt: try container.decodeIfPresent(String.self, forKey: .adoptedAt),
      metrics: try container.decode(SessionMetrics.self, forKey: .metrics)
    )
  }
}

public struct PendingLeaderTransfer: Codable, Equatable, Sendable {
  public let requestedBy: String
  public let currentLeaderId: String
  public let newLeaderId: String
  public let requestedAt: String
  public let reason: String?
}
