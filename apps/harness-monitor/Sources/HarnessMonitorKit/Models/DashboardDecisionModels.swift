import Foundation

/// Classifies a Dashboard decision so the detail surface can pick the right resolution control.
///
/// Derived from the persisted `Decision.ruleID`, so the raw strings must track the producers in
/// `PolicyExecutor` and the ACP/Codex sync paths.
public enum DashboardDecisionKind: String, Equatable, Sendable {
  case acpPermission
  case codexApproval
  case manual
  case supervisor

  public init(ruleID: String) {
    switch ruleID {
    case AcpPermissionDecisionPayload.ruleID: self = .acpPermission
    case "codex-approval": self = .codexApproval
    case "manual-session-window": self = .manual
    default: self = .supervisor
    }
  }
}

/// Where a decision points once it is lifted off its originating Session and shown in Dashboard
/// Agents. A manual decision names a managed agent, a work item, or a workspace instead of a
/// Session; `unattributed` covers rows with no resolvable workspace (for example a global
/// daemon-disconnect before any project is known).
public enum DashboardDecisionTarget: Hashable, Sendable {
  case agent(DashboardAgentIdentity)
  case workItem(workspace: DashboardAgentWorkspaceIdentity, taskID: String)
  case workspace(DashboardAgentWorkspaceIdentity)
  case unattributed

  public var agentIdentity: DashboardAgentIdentity? {
    if case .agent(let identity) = self { return identity }
    return nil
  }

  public var workspaceIdentity: DashboardAgentWorkspaceIdentity? {
    switch self {
    case .agent(let identity): identity.workspace
    case .workItem(let workspace, _): workspace
    case .workspace(let workspace): workspace
    case .unattributed: nil
    }
  }
}

/// A decision resolved for Dashboard presentation: the persisted row projected onto a target and
/// its workspace, ready to group and render without re-reading SwiftData.
public struct DashboardDecisionItem: Equatable, Identifiable, Sendable {
  public let id: String
  public let ruleID: String
  public let kind: DashboardDecisionKind
  public let severity: DecisionSeverity
  public let summary: String
  public let createdAt: Date
  public let target: DashboardDecisionTarget
  public let workspace: DashboardAgentWorkspace?

  public init(
    id: String,
    ruleID: String,
    kind: DashboardDecisionKind,
    severity: DecisionSeverity,
    summary: String,
    createdAt: Date,
    target: DashboardDecisionTarget,
    workspace: DashboardAgentWorkspace?
  ) {
    self.id = id
    self.ruleID = ruleID
    self.kind = kind
    self.severity = severity
    self.summary = summary
    self.createdAt = createdAt
    self.target = target
    self.workspace = workspace
  }
}

/// Per-agent rollup used to badge a list row without threading the full item list into it.
public struct DashboardAgentDecisionSummary: Equatable, Sendable {
  public let count: Int
  public let worstSeverity: DecisionSeverity

  public init(count: Int, worstSeverity: DecisionSeverity) {
    self.count = count
    self.worstSeverity = worstSeverity
  }
}

/// Decisions that name a workspace rather than a loaded agent, grouped for a per-workspace entry
/// in the agent list so nothing is orphaned when its agent is absent.
public struct DashboardDecisionWorkspaceBucket: Equatable, Identifiable, Sendable {
  public let workspace: DashboardAgentWorkspace
  public let items: [DashboardDecisionItem]

  public init(workspace: DashboardAgentWorkspace, items: [DashboardDecisionItem]) {
    self.workspace = workspace
    self.items = items
  }

  public var id: DashboardAgentWorkspaceIdentity { workspace.identity }

  public var worstSeverity: DecisionSeverity {
    items.map(\.severity).max(by: { $0.attributionRank < $1.attributionRank }) ?? .info
  }
}

extension DecisionSeverity {
  /// Ranks severities for worst-first ordering. Mirrors the UI `sortKey`, kept in-module so the
  /// pure attributor does not depend on the previewable target.
  var attributionRank: Int {
    switch self {
    case .critical: 4
    case .needsUser: 3
    case .warn: 2
    case .info: 1
    }
  }
}
