import Foundation
import HarnessMonitorCore

struct MobileRemoteManagedAgentListWire: Decodable, Sendable {
  var agents: [MobileRemoteManagedAgentWire]
}

enum MobileRemoteManagedAgentWire: Decodable, Sendable {
  case terminal(MobileRemoteTerminalAgentWire)
  case codex(MobileRemoteCodexAgentWire)
  case acp(MobileRemoteAcpAgentWire)

  var managedAgentID: String {
    switch self {
    case .terminal(let agent): agent.id
    case .codex(let agent): agent.id
    case .acp(let agent): agent.id
    }
  }

  var permissionBatches: [MobileRemoteAcpPermissionBatchWire] {
    guard case .acp(let agent) = self else {
      return []
    }
    return agent.permissionBatches
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "terminal":
      self = .terminal(try container.decode(MobileRemoteTerminalAgentWire.self, forKey: .snapshot))
    case "codex":
      self = .codex(try container.decode(MobileRemoteCodexAgentWire.self, forKey: .snapshot))
    case "acp":
      self = .acp(try container.decode(MobileRemoteAcpAgentWire.self, forKey: .snapshot))
    case let kind:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "unknown remote managed-agent kind \(kind)"
      )
    }
  }

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAgentSummary {
    switch self {
    case .terminal(let agent):
      agent.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    case .codex(let agent):
      agent.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    case .acp(let agent):
      agent.mobileSummary(stationID: stationID, now: now, redactor: redactor)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case snapshot
  }
}

struct MobileRemoteTerminalAgentWire: Decodable, Sendable {
  var id: String
  var sessionID: String
  var agentID: String
  var runtime: String
  var status: String
  var projectDir: String
  var error: String?
  var updatedAt: String

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAgentSummary {
    MobileAgentSummary(
      id: id,
      stationID: stationID,
      sessionID: sessionID,
      displayName: redactor.redact("\(runtime) \(agentID)"),
      family: .terminal,
      status: status.remoteAgentStatusTitle,
      isActive: ["starting", "running"].contains(status),
      isBlocked: status == "failed",
      lastActivityAt: MobileRemoteSessionDate.parse(updatedAt) ?? now,
      summary: redactor.redact(error ?? projectDir)
    )
  }

  enum CodingKeys: String, CodingKey {
    case id = "tui_id"
    case sessionID = "session_id"
    case agentID = "agent_id"
    case runtime
    case status
    case projectDir = "project_dir"
    case error
    case updatedAt = "updated_at"
  }
}

struct MobileRemoteCodexAgentWire: Decodable, Sendable {
  var id: String
  var sessionID: String
  var displayName: String?
  var projectDir: String
  var status: String
  var prompt: String
  var latestSummary: String?
  var finalMessage: String?
  var error: String?
  var pendingApprovalCount: Int
  var updatedAt: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    projectDir = try container.decode(String.self, forKey: .projectDir)
    status = try container.decode(String.self, forKey: .status)
    prompt = try container.decode(String.self, forKey: .prompt)
    latestSummary = try container.decodeIfPresent(String.self, forKey: .latestSummary)
    finalMessage = try container.decodeIfPresent(String.self, forKey: .finalMessage)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    pendingApprovalCount =
      try container.decodeIfPresent(
        [MobileRemoteIgnoredWire].self,
        forKey: .pendingApprovals
      )?.count ?? 0
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
  }

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAgentSummary {
    MobileAgentSummary(
      id: id,
      stationID: stationID,
      sessionID: sessionID,
      displayName: redactor.redact(displayName ?? id),
      family: .codex,
      status: status.remoteAgentStatusTitle,
      isActive: ["queued", "running", "waiting_approval"].contains(status),
      isBlocked: status == "waiting_approval" || pendingApprovalCount > 0 || status == "failed",
      pendingApprovalCount: pendingApprovalCount,
      lastActivityAt: MobileRemoteSessionDate.parse(updatedAt) ?? now,
      summary: redactor.redact(latestSummary ?? finalMessage ?? error ?? prompt)
    )
  }

  enum CodingKeys: String, CodingKey {
    case id = "run_id"
    case sessionID = "session_id"
    case displayName = "display_name"
    case projectDir = "project_dir"
    case status
    case prompt
    case latestSummary = "latest_summary"
    case finalMessage = "final_message"
    case error
    case pendingApprovals = "pending_approvals"
    case updatedAt = "updated_at"
  }
}

struct MobileRemoteAcpAgentWire: Decodable, Sendable {
  var id: String
  var sessionID: String
  var displayName: String
  var status: MobileRemoteAcpStatusWire
  var projectDir: String
  var pendingPermissions: Int
  var permissionBatches: [MobileRemoteAcpPermissionBatchWire]
  var updatedAt: String

  func mobileSummary(
    stationID: String,
    now: Date,
    redactor: MobileMirrorSecretRedactor
  ) -> MobileAgentSummary {
    MobileAgentSummary(
      id: id,
      stationID: stationID,
      sessionID: sessionID,
      displayName: redactor.redact(displayName),
      family: .acp,
      status: status.value.remoteAgentStatusTitle,
      isActive: status.value == "active",
      isBlocked: pendingPermissions > 0 || status.value == "awaiting_review",
      pendingPermissionCount: pendingPermissions,
      lastActivityAt: MobileRemoteSessionDate.parse(updatedAt) ?? now,
      summary: redactor.redact(status.stderrTail ?? projectDir)
    )
  }

  enum CodingKeys: String, CodingKey {
    case id = "managed_agent_id"
    case sessionID = "session_id"
    case displayName = "display_name"
    case status
    case projectDir = "project_dir"
    case pendingPermissions = "pending_permissions"
    case permissionBatches = "pending_permission_batches"
    case updatedAt = "updated_at"
  }
}

struct MobileRemoteAcpPermissionBatchWire: Decodable, Sendable {
  var batchID: String
  var managedAgentID: String
  var sessionID: String
  var requestCount: Int
  var createdAt: String

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    batchID = try container.decode(String.self, forKey: .batchID)
    managedAgentID = try container.decode(String.self, forKey: .managedAgentID)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    requestCount =
      try container.decodeIfPresent(
        [MobileRemoteIgnoredWire].self,
        forKey: .requests
      )?.count ?? 0
    createdAt = try container.decode(String.self, forKey: .createdAt)
  }

  enum CodingKeys: String, CodingKey {
    case batchID = "batch_id"
    case managedAgentID = "managed_agent_id"
    case sessionID = "session_id"
    case requests
    case createdAt = "created_at"
  }
}

struct MobileRemoteAcpStatusWire: Decodable, Sendable {
  var value: String
  var stderrTail: String?

  init(from decoder: any Decoder) throws {
    let single = try decoder.singleValueContainer()
    if let value = try? single.decode(String.self) {
      self.value = value
      stderrTail = nil
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    value = try container.decode(String.self, forKey: .value)
    stderrTail = try container.decodeIfPresent(String.self, forKey: .stderrTail)
  }

  enum CodingKeys: String, CodingKey {
    case value = "state"
    case stderrTail = "stderr_tail"
  }
}

private struct MobileRemoteIgnoredWire: Decodable, Sendable {
  init(from _: any Decoder) throws {}
}

extension String {
  fileprivate var remoteAgentStatusTitle: String {
    replacingOccurrences(of: "_", with: " ").capitalized
  }
}
