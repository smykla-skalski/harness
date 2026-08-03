import Foundation

/// One decision projected into the fields the attributor needs, precomputed at the store boundary:
/// the persisted row plus its resolved workspace and, for ACP rows, the daemon-managed agent id.
public struct DashboardDecisionAttributionInput: Equatable, Sendable {
  public let id: String
  public let ruleID: String
  public let severity: DecisionSeverity
  public let summary: String
  public let createdAt: Date
  public let sessionID: String?
  public let sessionAgentID: String?
  public let taskID: String?
  public let managedAgentID: String?
  public let workspace: DashboardAgentWorkspace?

  public init(
    id: String,
    ruleID: String,
    severity: DecisionSeverity,
    summary: String,
    createdAt: Date,
    sessionID: String?,
    sessionAgentID: String?,
    taskID: String?,
    managedAgentID: String?,
    workspace: DashboardAgentWorkspace?
  ) {
    self.id = id
    self.ruleID = ruleID
    self.severity = severity
    self.summary = summary
    self.createdAt = createdAt
    self.sessionID = sessionID
    self.sessionAgentID = sessionAgentID
    self.taskID = taskID
    self.managedAgentID = managedAgentID
    self.workspace = workspace
  }
}

/// The grouped decisions Dashboard Agents renders: per-agent lists and badge rollups for loaded
/// agents, per-workspace buckets for agent-less rows, and a shared bucket for rows with no
/// resolvable workspace.
public struct DashboardDecisionResolution: Equatable, Sendable {
  public let allItems: [DashboardDecisionItem]
  public let itemsByAgent: [DashboardAgentIdentity: [DashboardDecisionItem]]
  public let summaryByAgent: [DashboardAgentIdentity: DashboardAgentDecisionSummary]
  public let workspaceBuckets: [DashboardDecisionWorkspaceBucket]
  public let unattributedItems: [DashboardDecisionItem]

  public init(
    allItems: [DashboardDecisionItem],
    itemsByAgent: [DashboardAgentIdentity: [DashboardDecisionItem]],
    summaryByAgent: [DashboardAgentIdentity: DashboardAgentDecisionSummary],
    workspaceBuckets: [DashboardDecisionWorkspaceBucket],
    unattributedItems: [DashboardDecisionItem]
  ) {
    self.allItems = allItems
    self.itemsByAgent = itemsByAgent
    self.summaryByAgent = summaryByAgent
    self.workspaceBuckets = workspaceBuckets
    self.unattributedItems = unattributedItems
  }

  public static let empty = Self(
    allItems: [],
    itemsByAgent: [:],
    summaryByAgent: [:],
    workspaceBuckets: [],
    unattributedItems: []
  )
}

/// Pure mapping from open decisions to their Dashboard Agents grouping. Agent attribution matches a
/// loaded agent first (ACP by managed id + workspace, others by session agent id); rows that name a
/// workspace or work item but no loaded agent fall through to a workspace bucket.
public enum DashboardDecisionAttributor {
  public static func resolve(
    inputs: [DashboardDecisionAttributionInput],
    agents: [DashboardAgentSummary]
  ) -> DashboardDecisionResolution {
    let agentsByIdentity = Dictionary(
      agents.map { ($0.identity, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var agentBySessionAgent: [SessionAgentKey: DashboardAgentIdentity] = [:]
    for agent in agents {
      guard let sessionAgentID = agent.sessionAgentID else { continue }
      agentBySessionAgent[SessionAgentKey(sessionID: agent.sessionID, sessionAgentID: sessionAgentID)]
        = agent.identity
    }

    let items = inputs.map { input in
      item(
        for: input,
        agentsByIdentity: agentsByIdentity,
        agentBySessionAgent: agentBySessionAgent
      )
    }

    var itemsByAgent: [DashboardAgentIdentity: [DashboardDecisionItem]] = [:]
    var bucketItems: [DashboardAgentWorkspaceIdentity: (DashboardAgentWorkspace, [DashboardDecisionItem])] = [:]
    var unattributed: [DashboardDecisionItem] = []
    for item in items {
      switch item.target {
      case .agent(let identity):
        itemsByAgent[identity, default: []].append(item)
      case .workItem(let workspaceID, _), .workspace(let workspaceID):
        guard let workspace = item.workspace else {
          unattributed.append(item)
          continue
        }
        var existing = bucketItems[workspaceID]?.1 ?? []
        existing.append(item)
        bucketItems[workspaceID] = (workspace, existing)
      case .unattributed:
        unattributed.append(item)
      }
    }

    itemsByAgent = itemsByAgent.mapValues { $0.sorted(by: worstFirst) }
    let summaryByAgent = itemsByAgent.mapValues(summary(for:))
    let workspaceBuckets = bucketItems.values
      .map { DashboardDecisionWorkspaceBucket(workspace: $0.0, items: $0.1.sorted(by: worstFirst)) }
      .sorted(by: bucketOrdering)

    return DashboardDecisionResolution(
      allItems: items.sorted(by: worstFirst),
      itemsByAgent: itemsByAgent,
      summaryByAgent: summaryByAgent,
      workspaceBuckets: workspaceBuckets,
      unattributedItems: unattributed.sorted(by: worstFirst)
    )
  }

  private static func item(
    for input: DashboardDecisionAttributionInput,
    agentsByIdentity: [DashboardAgentIdentity: DashboardAgentSummary],
    agentBySessionAgent: [SessionAgentKey: DashboardAgentIdentity]
  ) -> DashboardDecisionItem {
    let target = target(
      for: input,
      agentsByIdentity: agentsByIdentity,
      agentBySessionAgent: agentBySessionAgent
    )
    let workspace = input.workspace ?? target.agentIdentity.flatMap { agentsByIdentity[$0]?.workspace }
    return DashboardDecisionItem(
      id: input.id,
      ruleID: input.ruleID,
      kind: DashboardDecisionKind(ruleID: input.ruleID),
      severity: input.severity,
      summary: input.summary,
      createdAt: input.createdAt,
      target: target,
      workspace: workspace
    )
  }

  private static func target(
    for input: DashboardDecisionAttributionInput,
    agentsByIdentity: [DashboardAgentIdentity: DashboardAgentSummary],
    agentBySessionAgent: [SessionAgentKey: DashboardAgentIdentity]
  ) -> DashboardDecisionTarget {
    if let managedAgentID = input.managedAgentID, let workspace = input.workspace {
      let identity = DashboardAgentIdentity(
        workspace: workspace.identity,
        runtimeKind: .acp,
        managedAgentID: managedAgentID
      )
      if agentsByIdentity[identity] != nil { return .agent(identity) }
    }
    if let sessionID = input.sessionID, let sessionAgentID = input.sessionAgentID,
      let identity = agentBySessionAgent[SessionAgentKey(sessionID: sessionID, sessionAgentID: sessionAgentID)]
    {
      return .agent(identity)
    }
    if let workspace = input.workspace, let taskID = input.taskID, !taskID.isEmpty {
      return .workItem(workspace: workspace.identity, taskID: taskID)
    }
    if let workspace = input.workspace {
      return .workspace(workspace.identity)
    }
    return .unattributed
  }

  private static func summary(
    for items: [DashboardDecisionItem]
  ) -> DashboardAgentDecisionSummary {
    let worst = items.map(\.severity).max(by: { $0.attributionRank < $1.attributionRank }) ?? .info
    return DashboardAgentDecisionSummary(count: items.count, worstSeverity: worst)
  }

  private static func worstFirst(
    _ lhs: DashboardDecisionItem,
    _ rhs: DashboardDecisionItem
  ) -> Bool {
    if lhs.severity.attributionRank != rhs.severity.attributionRank {
      return lhs.severity.attributionRank > rhs.severity.attributionRank
    }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id < rhs.id
  }

  private static func bucketOrdering(
    _ lhs: DashboardDecisionWorkspaceBucket,
    _ rhs: DashboardDecisionWorkspaceBucket
  ) -> Bool {
    let left = "\(lhs.workspace.title)\u{0}\(lhs.workspace.subtitle)"
    let right = "\(rhs.workspace.title)\u{0}\(rhs.workspace.subtitle)"
    return left.localizedStandardCompare(right) == .orderedAscending
  }
}

private struct SessionAgentKey: Hashable {
  let sessionID: String
  let sessionAgentID: String
}
