import Foundation

public enum CodexRunMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case report
  case workspaceWrite = "workspace_write"
  case approval

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .report:
      "Report"
    case .workspaceWrite:
      "Workspace Write"
    case .approval:
      "Approval"
    }
  }
}

public enum CodexRunStatus: String, Codable, Sendable {
  case queued
  case running
  case waitingApproval = "waiting_approval"
  case completed
  case failed
  case cancelled

  public var title: String {
    switch self {
    case .queued:
      "Queued"
    case .running:
      "Running"
    case .waitingApproval:
      "Waiting Approval"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }

  public var isActive: Bool {
    switch self {
    case .queued, .running, .waitingApproval:
      true
    case .completed, .failed, .cancelled:
      false
    }
  }
}

public enum CodexApprovalDecision: String, Codable, CaseIterable, Sendable {
  case accept
  case acceptForSession = "accept_for_session"
  case decline
  case cancel
}

public struct CodexRunRequest: Codable, Equatable, Sendable {
  public let actor: String?
  public let prompt: String
  public let mode: CodexRunMode
  public let resumeThreadId: String?

  public init(
    actor: String?,
    prompt: String,
    mode: CodexRunMode,
    resumeThreadId: String? = nil
  ) {
    self.actor = actor
    self.prompt = prompt
    self.mode = mode
    self.resumeThreadId = resumeThreadId
  }
}

public struct CodexSteerRequest: Codable, Equatable, Sendable {
  public let prompt: String
}

public struct CodexApprovalDecisionRequest: Codable, Equatable, Sendable {
  public let decision: CodexApprovalDecision
}

public struct CodexRunListResponse: Codable, Equatable, Sendable {
  public let runs: [CodexRunSnapshot]
}

public struct CodexApprovalRequest: Codable, Equatable, Identifiable, Sendable {
  public let approvalId: String
  public let requestId: String
  public let kind: String
  public let title: String
  public let detail: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let cwd: String?
  public let command: String?
  public let filePath: String?

  public var id: String { approvalId }
}

public struct CodexRunSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let projectDir: String
  public let threadId: String?
  public let turnId: String?
  public let mode: CodexRunMode
  public let status: CodexRunStatus
  public let prompt: String
  public let latestSummary: String?
  public let finalMessage: String?
  public let error: String?
  public let pendingApprovals: [CodexApprovalRequest]
  public let createdAt: String
  public let updatedAt: String

  public var id: String { runId }
}

public struct CodexApprovalRequestedPayload: Codable, Equatable, Sendable {
  public let run: CodexRunSnapshot
  public let approval: CodexApprovalRequest
}

public enum AgentTuiRuntime: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex
  case claude
  case gemini
  case copilot
  case vibe

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
}

public struct AgentTuiListResponse: Codable, Equatable, Sendable {
  public let tuis: [AgentTuiSnapshot]
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

public extension AgentTuiListResponse {
  func canonicallySorted(roleByAgent: [String: SessionRole]) -> Self {
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

public extension AgentTuiStatus {
  var sortPriority: Int {
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

private extension AgentTuiSnapshot {
  func roleSortPriority(roleByAgent: [String: SessionRole]) -> Int {
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

public struct AgentTuiInputRequest: Codable, Equatable, Sendable {
  public let input: AgentTuiInput

  public init(input: AgentTuiInput) {
    self.input = input
  }
}

public enum AgentTuiInput: Codable, Equatable, Sendable {
  case text(String)
  case paste(String)
  case key(AgentTuiKey)
  case control(Character)
  case rawBytesBase64(String)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case key
    case data
  }

  enum InputType: String, Codable {
    case text
    case paste
    case key
    case control
    case rawBytesBase64 = "raw_bytes_base64"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(InputType.self, forKey: .type)
    switch type {
    case .text:
      self = .text(try container.decode(String.self, forKey: .text))
    case .paste:
      self = .paste(try container.decode(String.self, forKey: .text))
    case .key:
      self = .key(try container.decode(AgentTuiKey.self, forKey: .key))
    case .control:
      let value = try container.decode(String.self, forKey: .key)
      guard let character = value.first, value.count == 1 else {
        throw DecodingError.dataCorruptedError(
          forKey: .key,
          in: container,
          debugDescription: "Control key must be exactly one character."
        )
      }
      self = .control(character)
    case .rawBytesBase64:
      self = .rawBytesBase64(try container.decode(String.self, forKey: .data))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode(InputType.text, forKey: .type)
      try container.encode(text, forKey: .text)
    case .paste(let text):
      try container.encode(InputType.paste, forKey: .type)
      try container.encode(text, forKey: .text)
    case .key(let key):
      try container.encode(InputType.key, forKey: .type)
      try container.encode(key, forKey: .key)
    case .control(let key):
      try container.encode(InputType.control, forKey: .type)
      try container.encode(String(key), forKey: .key)
    case .rawBytesBase64(let data):
      try container.encode(InputType.rawBytesBase64, forKey: .type)
      try container.encode(data, forKey: .data)
    }
  }
}
