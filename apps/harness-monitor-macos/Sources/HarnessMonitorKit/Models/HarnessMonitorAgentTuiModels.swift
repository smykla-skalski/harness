import Foundation

public enum AgentTuiRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex
  case claude
  case gemini
  case copilot
  case vibe
  case opencode

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .codex:
      "Codex"
    case .claude:
      "Claude"
    case .gemini:
      "Gemini"
    case .copilot:
      "Copilot"
    case .vibe:
      "Vibe"
    case .opencode:
      "OpenCode"
    }
  }
}

public enum AgentTuiStatus: String, Codable, Sendable {
  case running
  case stopped
  case exited
  case failed

  public var title: String {
    switch self {
    case .running:
      "Running"
    case .stopped:
      "Stopped"
    case .exited:
      "Exited"
    case .failed:
      "Failed"
    }
  }

  public var isActive: Bool {
    switch self {
    case .running:
      true
    case .stopped, .exited, .failed:
      false
    }
  }
}

public enum AgentTuiKey: String, Codable, CaseIterable, Identifiable, Sendable {
  case enter
  case escape
  case tab
  case backspace
  case arrowUp = "arrow_up"
  case arrowDown = "arrow_down"
  case arrowRight = "arrow_right"
  case arrowLeft = "arrow_left"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .enter:
      "Enter"
    case .escape:
      "Esc"
    case .tab:
      "Tab"
    case .backspace:
      "Backspace"
    case .arrowUp:
      "Up"
    case .arrowDown:
      "Down"
    case .arrowRight:
      "Right"
    case .arrowLeft:
      "Left"
    }
  }

  public var glyph: String {
    switch self {
    case .enter:
      "↩"
    case .escape:
      "⎋"
    case .tab:
      "⇥"
    case .backspace:
      "⌫"
    case .arrowUp:
      "↑"
    case .arrowDown:
      "↓"
    case .arrowRight:
      "→"
    case .arrowLeft:
      "←"
    }
  }
}

public struct AgentTuiSize: Codable, Equatable, Sendable {
  public let rows: Int
  public let cols: Int

  public init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
  }
}

public struct AgentTuiScreenSnapshot: Codable, Equatable, Sendable {
  public let rows: Int
  public let cols: Int
  public let cursorRow: Int
  public let cursorCol: Int
  public let text: String

  public static let defaultVisibleRowLimit = 400

  public struct VisibleRow: Equatable, Identifiable, Sendable {
    public let id: Int
    public let text: String
  }

  public func visibleRows(maxRows: Int = defaultVisibleRowLimit) -> [VisibleRow] {
    let limit = Swift.max(0, maxRows)
    guard !text.isEmpty, limit > 0 else {
      return []
    }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let startIndex = Swift.max(0, lines.count - limit)
    return lines[startIndex...].enumerated().map { offset, line in
      VisibleRow(id: startIndex + offset, text: String(line))
    }
  }
}

public struct AgentTuiListResponse: Codable, Equatable, Sendable {
  public let tuis: [AgentTuiSnapshot]
}

public struct ManagedAgentListResponse: Codable, Equatable, Sendable {
  public let agents: [ManagedAgentSnapshot]
}

public enum ManagedAgentSnapshot: Equatable, Identifiable, Sendable {
  case terminal(AgentTuiSnapshot)
  case codex(CodexRunSnapshot)
  case acp(AcpAgentSnapshot)

  public var id: String { agentId }

  public var agentId: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.tuiId
    case .codex(let snapshot):
      snapshot.runId
    case .acp(let snapshot):
      snapshot.acpId
    }
  }

  public var sessionId: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.sessionId
    case .codex(let snapshot):
      snapshot.sessionId
    case .acp(let snapshot):
      snapshot.sessionId
    }
  }

  public var updatedAt: String {
    switch self {
    case .terminal(let snapshot):
      snapshot.updatedAt
    case .codex(let snapshot):
      snapshot.updatedAt
    case .acp(let snapshot):
      snapshot.updatedAt
    }
  }

  public var terminal: AgentTuiSnapshot? {
    guard case .terminal(let snapshot) = self else { return nil }
    return snapshot
  }

  public var codex: CodexRunSnapshot? {
    guard case .codex(let snapshot) = self else { return nil }
    return snapshot
  }

  public var acp: AcpAgentSnapshot? {
    guard case .acp(let snapshot) = self else { return nil }
    return snapshot
  }
}

extension ManagedAgentSnapshot: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind
    case snapshot
  }

  private enum Kind: String, Codable {
    case terminal
    case codex
    case acp
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .terminal:
      self = .terminal(try container.decode(AgentTuiSnapshot.self, forKey: .snapshot))
    case .codex:
      self = .codex(try container.decode(CodexRunSnapshot.self, forKey: .snapshot))
    case .acp:
      self = .acp(try container.decode(AcpAgentSnapshot.self, forKey: .snapshot))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .terminal(let snapshot):
      try container.encode(Kind.terminal, forKey: .kind)
      try container.encode(snapshot, forKey: .snapshot)
    case .codex(let snapshot):
      try container.encode(Kind.codex, forKey: .kind)
      try container.encode(snapshot, forKey: .snapshot)
    case .acp(let snapshot):
      try container.encode(Kind.acp, forKey: .kind)
      try container.encode(snapshot, forKey: .snapshot)
    }
  }
}

public struct AgentTuiSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let tuiId: String
  public let sessionId: String
  public let agentId: String
  public let runtime: String
  public let status: AgentTuiStatus
  public let argv: [String]
  public let projectDir: String
  public let size: AgentTuiSize
  public let screen: AgentTuiScreenSnapshot
  public let transcriptPath: String
  public let exitCode: UInt32?
  public let signal: String?
  public let error: String?
  public let createdAt: String
  public let updatedAt: String

  public var id: String { tuiId }
}

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
      })
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

extension AgentTuiSnapshot {
  fileprivate func roleSortPriority(roleByAgent: [String: SessionRole]) -> Int {
    roleByAgent[agentId]?.sortPriority ?? SessionRole.worker.sortPriority
  }
}

public struct AgentTuiStartRequest: Codable, Equatable, Sendable {
  public let runtime: String
  public let role: SessionRole
  public let capabilities: [String]
  public let name: String?
  public let prompt: String?
  public let projectDir: String?
  public let persona: String?
  public let model: String?
  public let effort: String?
  public let allowCustomModel: Bool
  public let argv: [String]
  public let rows: Int
  public let cols: Int

  public init(
    runtime: String,
    role: SessionRole = .worker,
    capabilities: [String] = [],
    name: String? = nil,
    prompt: String? = nil,
    projectDir: String? = nil,
    persona: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false,
    argv: [String] = [],
    rows: Int = 32,
    cols: Int = 120
  ) {
    self.runtime = runtime
    self.role = role
    self.capabilities = capabilities
    self.name = name
    self.prompt = prompt
    self.projectDir = projectDir
    self.persona = persona
    self.model = model
    self.effort = effort
    self.allowCustomModel = allowCustomModel
    self.argv = argv
    self.rows = rows
    self.cols = cols
  }
}

public struct AgentTuiResizeRequest: Codable, Equatable, Sendable {
  public let rows: Int
  public let cols: Int

  public init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
  }
}
