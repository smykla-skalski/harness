import Foundation

extension AgentTuiListResponse {
  public func canonicallySorted(roleByAgent: [String: SessionRole]) -> Self {
    Self(
      tuis: tuis.sorted { left, right in
        if left.roleSortPriority(roleByAgent: roleByAgent)
          != right.roleSortPriority(roleByAgent: roleByAgent)
        {
          return left.roleSortPriority(roleByAgent: roleByAgent)
            < right.roleSortPriority(roleByAgent: roleByAgent)
        }
        if left.status.sortPriority != right.status.sortPriority {
          return left.status.sortPriority < right.status.sortPriority
        }
        if left.runtime != right.runtime {
          return left.runtime < right.runtime
        }
        if left.agentId != right.agentId {
          return left.agentId < right.agentId
        }
        if left.createdAt != right.createdAt {
          return left.createdAt > right.createdAt
        }
        return left.tuiId < right.tuiId
      }
    )
  }
}

extension ManagedAgentListResponse {
  public var terminals: [AgentTuiSnapshot] {
    agents.compactMap(\.terminal)
  }

  public var codexRuns: [CodexRunSnapshot] {
    agents.compactMap(\.codex)
  }

  public var terminalListResponse: AgentTuiListResponse {
    AgentTuiListResponse(tuis: terminals)
  }

  public var codexRunListResponse: CodexRunListResponse {
    CodexRunListResponse(runs: codexRuns)
  }
}

extension AgentTuiStatus {
  public var sortPriority: Int {
    switch self {
    case .running:
      0
    case .stopped:
      1
    case .exited:
      2
    case .failed:
      3
    }
  }
}

public enum ManagedAgentFamily: String, Codable, Sendable {
  case terminal
  case codex
  case acp
  case openRouter = "open_router"
}

extension AgentTuiSnapshot {
  fileprivate func roleSortPriority(roleByAgent: [String: SessionRole]) -> Int {
    roleByAgent[agentId]?.sortPriority ?? SessionRole.worker.sortPriority
  }
}
