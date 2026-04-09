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
  case ended

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .paused:
      "Paused"
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
  public let checkoutId: String
  public let checkoutRoot: String
  public let isWorktree: Bool
  public let worktreeName: String?
  public let sessionId: String
  public let title: String
  public let context: String
  public let status: SessionStatus
  public let createdAt: String
  public let updatedAt: String
  public let lastActivityAt: String?
  public let leaderId: String?
  public let observeId: String?
  public let pendingLeaderTransfer: PendingLeaderTransfer?
  public let metrics: SessionMetrics

  public var id: String { sessionId }

  public var displayTitle: String { title.isEmpty ? "(untitled)" : title }

  public init(
    projectId: String,
    projectName: String,
    projectDir: String?,
    contextRoot: String,
    checkoutId: String? = nil,
    checkoutRoot: String? = nil,
    isWorktree: Bool = false,
    worktreeName: String? = nil,
    sessionId: String,
    title: String = "",
    context: String,
    status: SessionStatus,
    createdAt: String,
    updatedAt: String,
    lastActivityAt: String?,
    leaderId: String?,
    observeId: String?,
    pendingLeaderTransfer: PendingLeaderTransfer?,
    metrics: SessionMetrics
  ) {
    self.projectId = projectId
    self.projectName = projectName
    self.projectDir = projectDir
    self.contextRoot = contextRoot
    self.checkoutId = checkoutId ?? projectId
    self.checkoutRoot = checkoutRoot ?? projectDir ?? contextRoot
    self.isWorktree = isWorktree
    self.worktreeName = worktreeName
    self.sessionId = sessionId
    self.title = title
    self.context = context
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.lastActivityAt = lastActivityAt
    self.leaderId = leaderId
    self.observeId = observeId
    self.pendingLeaderTransfer = pendingLeaderTransfer
    self.metrics = metrics
  }

  public var checkoutDisplayName: String {
    if isWorktree {
      return worktreeName ?? URL(fileURLWithPath: checkoutRoot).lastPathComponent
    }
    return "Repository"
  }

  enum CodingKeys: String, CodingKey {
    case projectId, projectName, projectDir, contextRoot
    case checkoutId, checkoutRoot, isWorktree, worktreeName
    case sessionId, title, context, status, createdAt, updatedAt, lastActivityAt
    case leaderId, observeId, pendingLeaderTransfer, metrics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let projectId = try container.decode(String.self, forKey: .projectId)
    let projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
    let contextRoot = try container.decode(String.self, forKey: .contextRoot)
    self.init(
      projectId: projectId,
      projectName: try container.decode(String.self, forKey: .projectName),
      projectDir: projectDir,
      contextRoot: contextRoot,
      checkoutId: try container.decodeIfPresent(String.self, forKey: .checkoutId) ?? projectId,
      checkoutRoot: try container.decodeIfPresent(String.self, forKey: .checkoutRoot)
        ?? projectDir ?? contextRoot,
      isWorktree: try container.decodeIfPresent(Bool.self, forKey: .isWorktree) ?? false,
      worktreeName: try container.decodeIfPresent(String.self, forKey: .worktreeName),
      sessionId: try container.decode(String.self, forKey: .sessionId),
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
