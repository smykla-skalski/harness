import Foundation

public enum DashboardAgentRuntimeKind: String, Codable, CaseIterable, Hashable, Sendable {
  case terminal
  case codex
  case acp

  public var title: String {
    switch self {
    case .terminal: "Terminal"
    case .codex: "Codex"
    case .acp: "ACP"
    }
  }
}

public struct DashboardAgentWorkspaceIdentity: Codable, Hashable, Sendable {
  public let projectID: String
  public let checkoutID: String

  public init(projectID: String, checkoutID: String) {
    self.projectID = projectID
    self.checkoutID = checkoutID
  }

  public var selectionRawValue: String {
    guard let data = try? DashboardAgentIdentityCoding.encoder.encode(self) else { return "" }
    return data.base64EncodedString()
  }

  public init?(selectionRawValue: String) {
    guard
      let data = Data(base64Encoded: selectionRawValue),
      let decoded = try? DashboardAgentIdentityCoding.decoder.decode(Self.self, from: data)
    else { return nil }
    self = decoded
  }
}

public struct DashboardAgentIdentity: Codable, Hashable, Identifiable, Sendable {
  public let workspace: DashboardAgentWorkspaceIdentity
  public let runtimeKind: DashboardAgentRuntimeKind
  public let managedAgentID: String

  public init(
    workspace: DashboardAgentWorkspaceIdentity,
    runtimeKind: DashboardAgentRuntimeKind,
    managedAgentID: String
  ) {
    self.workspace = workspace
    self.runtimeKind = runtimeKind
    self.managedAgentID = managedAgentID
  }

  public var id: String { selectionRawValue }

  public var selectionRawValue: String {
    guard let data = try? DashboardAgentIdentityCoding.encoder.encode(self) else { return "" }
    return data.base64EncodedString()
  }

  public init?(selectionRawValue: String) {
    guard
      let data = Data(base64Encoded: selectionRawValue),
      let decoded = try? DashboardAgentIdentityCoding.decoder.decode(Self.self, from: data)
    else { return nil }
    self = decoded
  }
}

private enum DashboardAgentIdentityCoding {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  static let decoder = JSONDecoder()
}

public struct DashboardAgentWorkspace: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let identity: DashboardAgentWorkspaceIdentity
  public let projectName: String
  public let checkoutName: String
  public let checkoutRoot: String

  public init(
    identity: DashboardAgentWorkspaceIdentity,
    projectName: String,
    checkoutName: String,
    checkoutRoot: String
  ) {
    self.identity = identity
    self.projectName = projectName
    self.checkoutName = checkoutName
    self.checkoutRoot = checkoutRoot
  }

  public var id: DashboardAgentWorkspaceIdentity { identity }

  public var title: String {
    projectName.isEmpty ? "Unknown project" : projectName
  }

  public var subtitle: String {
    checkoutName.isEmpty ? "main" : checkoutName
  }
}

public enum DashboardAgentLifecycle: String, Codable, Equatable, Sendable {
  case starting
  case active
  case waiting
  case idle
  case completed
  case stopped
  case disconnected
  case failed
  case unknown

  public var title: String {
    switch self {
    case .starting: "Starting"
    case .active: "Active"
    case .waiting: "Waiting"
    case .idle: "Idle"
    case .completed: "Completed"
    case .stopped: "Stopped"
    case .disconnected: "Disconnected"
    case .failed: "Failed"
    case .unknown: "Unknown"
    }
  }
}

public enum DashboardAgentDataSource: String, Codable, Equatable, Sendable {
  case live
  case mixed
  case cache
}

public enum DashboardAgentLoadIssue: Codable, Equatable, Sendable {
  case offline(String)
  case requestFailure(String)
}

public struct DashboardAgentSummary: Codable, Equatable, Identifiable, Sendable {
  public let identity: DashboardAgentIdentity
  public let workspace: DashboardAgentWorkspace
  public let sessionID: String
  public let sessionAgentID: String?
  public let displayName: String
  public let lifecycle: DashboardAgentLifecycle
  public let summary: String?
  public let projectDirectory: String
  public let createdAt: String
  public let updatedAt: String
  public let source: DashboardAgentDataSource

  public init(
    identity: DashboardAgentIdentity,
    workspace: DashboardAgentWorkspace,
    sessionID: String,
    sessionAgentID: String?,
    displayName: String,
    lifecycle: DashboardAgentLifecycle,
    summary: String?,
    projectDirectory: String,
    createdAt: String,
    updatedAt: String,
    source: DashboardAgentDataSource
  ) {
    self.identity = identity
    self.workspace = workspace
    self.sessionID = sessionID
    self.sessionAgentID = sessionAgentID
    self.displayName = displayName
    self.lifecycle = lifecycle
    self.summary = summary
    self.projectDirectory = projectDirectory
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.source = source
  }

  public var id: DashboardAgentIdentity { identity }
  public var runtimeKind: DashboardAgentRuntimeKind { identity.runtimeKind }
  public var managedAgentID: String { identity.managedAgentID }
}

public struct DashboardAgentWorkspaceGroup: Equatable, Identifiable, Sendable {
  public let workspace: DashboardAgentWorkspace
  public let agents: [DashboardAgentSummary]

  public var id: DashboardAgentWorkspaceIdentity { workspace.identity }

  public static func make(from agents: [DashboardAgentSummary]) -> [Self] {
    let grouped = Dictionary(grouping: agents, by: \.workspace.identity)
    return grouped.values
      .compactMap { workspaceAgents in
        guard let workspace = workspaceAgents.first?.workspace else { return nil }
        return Self(
          workspace: workspace,
          agents: workspaceAgents.sorted(by: DashboardAgentSummary.sortsBefore)
        )
      }
      .sorted { lhs, rhs in
        let left = "\(lhs.workspace.title)\u{0}\(lhs.workspace.subtitle)"
        let right = "\(rhs.workspace.title)\u{0}\(rhs.workspace.subtitle)"
        return left.localizedStandardCompare(right) == .orderedAscending
      }
  }
}

public struct DashboardAgentCacheSnapshot: Equatable, Sendable {
  public let agents: [DashboardAgentSummary]
  public let cachedAt: Date?

  public init(agents: [DashboardAgentSummary], cachedAt: Date?) {
    self.agents = agents
    self.cachedAt = cachedAt
  }
}

public struct DashboardAgentRefreshResult: Equatable, Sendable {
  public let agents: [DashboardAgentSummary]
  public let source: DashboardAgentDataSource
  public let issue: DashboardAgentLoadIssue?
  public let refreshedAt: Date

  public init(
    agents: [DashboardAgentSummary],
    source: DashboardAgentDataSource,
    issue: DashboardAgentLoadIssue?,
    refreshedAt: Date
  ) {
    self.agents = agents
    self.source = source
    self.issue = issue
    self.refreshedAt = refreshedAt
  }

  static func merging(
    liveAgents: [DashboardAgentSummary],
    cachedAgents: [DashboardAgentSummary],
    successfulSessionIDs: Set<String>,
    failuresBySessionID: [String: String],
    refreshedAt: Date = .now
  ) -> Self {
    let fallback = cachedAgents.filter { !successfulSessionIDs.contains($0.sessionID) }
    let merged = DashboardAgentSummary.deduplicated(liveAgents + fallback)
    let issue = requestFailure(from: failuresBySessionID)
    let source: DashboardAgentDataSource
    if failuresBySessionID.isEmpty {
      source = .live
    } else if liveAgents.isEmpty {
      source = .cache
    } else {
      source = .mixed
    }
    return Self(agents: merged, source: source, issue: issue, refreshedAt: refreshedAt)
  }

  private static func requestFailure(
    from failuresBySessionID: [String: String]
  ) -> DashboardAgentLoadIssue? {
    guard !failuresBySessionID.isEmpty else { return nil }
    let messages = Array(Set(failuresBySessionID.values)).sorted()
    let prefix =
      failuresBySessionID.count == 1
      ? "1 workspace request failed"
      : "\(failuresBySessionID.count) workspace requests failed"
    return .requestFailure("\(prefix): \(messages.joined(separator: "; "))")
  }
}

extension DashboardAgentSummary {
  static func deduplicated(_ agents: [Self]) -> [Self] {
    var byIdentity: [DashboardAgentIdentity: Self] = [:]
    for agent in agents {
      guard let current = byIdentity[agent.identity] else {
        byIdentity[agent.identity] = agent
        continue
      }
      if current.updatedAt <= agent.updatedAt {
        byIdentity[agent.identity] = agent
      }
    }
    return byIdentity.values.sorted(by: sortsBefore)
  }

  fileprivate static func sortsBefore(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    if lhs.displayName != rhs.displayName {
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
    return lhs.identity.selectionRawValue < rhs.identity.selectionRawValue
  }
}
