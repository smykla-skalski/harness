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
  case awaitingLeader = "awaiting_leader"
  case active
  case paused
  case leaderlessDegraded = "leaderless_degraded"
  case ended

  public var title: String {
    switch self {
    case .awaitingLeader:
      "Awaiting Leader"
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
  public let idleAgentCount: Int
  public let awaitingReviewAgentCount: Int
  public let openTaskCount: Int
  public let inProgressTaskCount: Int
  public let awaitingReviewTaskCount: Int
  public let inReviewTaskCount: Int
  public let arbitrationTaskCount: Int
  public let blockedTaskCount: Int
  public let completedTaskCount: Int

  public init(
    agentCount: Int = 0,
    activeAgentCount: Int = 0,
    idleAgentCount: Int = 0,
    awaitingReviewAgentCount: Int = 0,
    openTaskCount: Int = 0,
    inProgressTaskCount: Int = 0,
    awaitingReviewTaskCount: Int = 0,
    inReviewTaskCount: Int = 0,
    arbitrationTaskCount: Int = 0,
    blockedTaskCount: Int = 0,
    completedTaskCount: Int = 0
  ) {
    self.agentCount = agentCount
    self.activeAgentCount = activeAgentCount
    self.idleAgentCount = idleAgentCount
    self.awaitingReviewAgentCount = awaitingReviewAgentCount
    self.openTaskCount = openTaskCount
    self.inProgressTaskCount = inProgressTaskCount
    self.awaitingReviewTaskCount = awaitingReviewTaskCount
    self.inReviewTaskCount = inReviewTaskCount
    self.arbitrationTaskCount = arbitrationTaskCount
    self.blockedTaskCount = blockedTaskCount
    self.completedTaskCount = completedTaskCount
  }

  enum CodingKeys: String, CodingKey {
    case agentCount, activeAgentCount, idleAgentCount, awaitingReviewAgentCount
    case openTaskCount, inProgressTaskCount, awaitingReviewTaskCount, inReviewTaskCount
    case arbitrationTaskCount, blockedTaskCount, completedTaskCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      agentCount: try container.decodeIfPresent(Int.self, forKey: .agentCount) ?? 0,
      activeAgentCount: try container.decodeIfPresent(Int.self, forKey: .activeAgentCount) ?? 0,
      idleAgentCount: try container.decodeIfPresent(Int.self, forKey: .idleAgentCount) ?? 0,
      awaitingReviewAgentCount:
        try container.decodeIfPresent(Int.self, forKey: .awaitingReviewAgentCount) ?? 0,
      openTaskCount: try container.decodeIfPresent(Int.self, forKey: .openTaskCount) ?? 0,
      inProgressTaskCount:
        try container.decodeIfPresent(Int.self, forKey: .inProgressTaskCount) ?? 0,
      awaitingReviewTaskCount:
        try container.decodeIfPresent(Int.self, forKey: .awaitingReviewTaskCount) ?? 0,
      inReviewTaskCount: try container.decodeIfPresent(Int.self, forKey: .inReviewTaskCount) ?? 0,
      arbitrationTaskCount:
        try container.decodeIfPresent(Int.self, forKey: .arbitrationTaskCount) ?? 0,
      blockedTaskCount: try container.decodeIfPresent(Int.self, forKey: .blockedTaskCount) ?? 0,
      completedTaskCount:
        try container.decodeIfPresent(Int.self, forKey: .completedTaskCount) ?? 0
    )
  }
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

  public var checkoutRoot: String {
    let normalizedOrigin = Self.normalizedPath(originPath)
    if !normalizedOrigin.isEmpty {
      return normalizedOrigin
    }
    let normalizedProjectDir = Self.normalizedPath(projectDir)
    if !normalizedProjectDir.isEmpty {
      return normalizedProjectDir
    }
    return contextRoot
  }

  public var isWorktree: Bool {
    let normalizedOrigin = Self.normalizedPath(originPath)
    guard !normalizedOrigin.isEmpty else {
      return false
    }
    if Self.knownWorktreeName(from: normalizedOrigin) != nil {
      return true
    }
    let normalizedProjectDir = Self.normalizedPath(projectDir)
    guard !normalizedProjectDir.isEmpty else {
      return false
    }
    return normalizedOrigin != normalizedProjectDir
  }

  public var worktreeName: String? {
    guard isWorktree else {
      return nil
    }
    if let knownWorktreeName = Self.knownWorktreeName(from: checkoutRoot) {
      return knownWorktreeName
    }
    let lastComponent = URL(fileURLWithPath: checkoutRoot).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return lastComponent.isEmpty ? nil : lastComponent
  }

  public var checkoutId: String {
    isWorktree ? checkoutRoot : projectId
  }

  public var checkoutDisplayName: String {
    if isWorktree {
      return worktreeName ?? URL(fileURLWithPath: checkoutRoot).lastPathComponent
    }
    return "Repository"
  }

  /// Display name for the origin checkout/worktree.
  public var worktreeDisplayName: String {
    checkoutDisplayName
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

  private static func normalizedPath(_ path: String?) -> String {
    guard let path else {
      return ""
    }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return ""
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
  }

  private static func knownWorktreeName(from path: String) -> String? {
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard
      let markerIndex = components.firstIndex(of: ".claude"),
      components.indices.contains(markerIndex + 2),
      components[markerIndex + 1] == "worktrees"
    else {
      return nil
    }
    let candidate = components[markerIndex + 2].trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? nil : candidate
  }
}

public struct PendingLeaderTransfer: Codable, Equatable, Sendable {
  public let requestedBy: String
  public let currentLeaderId: String
  public let newLeaderId: String
  public let requestedAt: String
  public let reason: String?
}
