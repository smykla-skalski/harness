import Foundation
import HarnessMonitorCore

extension MobileRemoteDaemonCommandRequestBuilder {
  static func agentRequest(
    _ command: MobileCommandRecord,
    agentKind: String?
  ) throws -> MobileRemoteDaemonCommandRequest {
    switch command.kind {
    case .agentStart:
      try agentStartRequest(command)
    case .agentStop:
      try agentStopRequest(command, agentKind: agentKind)
    case .agentPrompt:
      try agentPromptRequest(command, agentKind: agentKind)
    default:
      throw MobileRemoteDaemonSyncError.invalidCommand("not an agent command")
    }
  }

  private static func agentStartRequest(
    _ command: MobileCommandRecord
  ) throws -> MobileRemoteDaemonCommandRequest {
    let sessionID = try command.remoteRequiredSessionID().remotePathComponent()
    let agent = try command.remoteRequiredPayload("agent")
    let family = try agentFamily(command, agent: agent)
    var body = try commonAgentStartBody(command)
    let path: String
    switch family {
    case "terminal":
      body["runtime"] = terminalRuntime(command, agent: agent)
      body["argv"] = command.remoteCSVPayload("argv")
      body["rows"] = try command.remotePositiveIntPayload("rows") ?? 32
      body["cols"] = try command.remotePositiveIntPayload("cols") ?? 120
      path = "/v1/sessions/\(sessionID)/managed-agents/terminal"
    case "codex":
      body["prompt"] = try command.remoteRequiredPayload("prompt")
      body["actor"] = command.actorDeviceID
      body["mode"] = command.remoteOptionalPayload("mode") ?? "workspace_write"
      path = "/v1/sessions/\(sessionID)/managed-agents/codex"
    case "acp":
      let descriptorID =
        agent.lowercased().hasPrefix("acp:")
        ? String(agent.dropFirst(4)) : agent
      guard let descriptorID = descriptorID.remoteTrimmed else {
        throw MobileRemoteDaemonSyncError.invalidCommand("agent is required")
      }
      body["descriptor_id"] = descriptorID
      body["record_permissions"] = try command.remoteBoolPayload("recordPermissions") ?? true
      path = "/v1/sessions/\(sessionID)/managed-agents/acp"
    default:
      throw MobileRemoteDaemonSyncError.invalidCommand("unknown agent family: \(family)")
    }
    return try request(
      path: path,
      body: body,
      successMessage: "Started the managed agent directly."
    )
  }

  private static func agentStopRequest(
    _ command: MobileCommandRecord,
    agentKind: String?
  ) throws -> MobileRemoteDaemonCommandRequest {
    let agentID = try command.remoteRequiredAgentID().remotePathComponent()
    switch agentKind {
    case "terminal":
      return try request(
        path: "/v1/managed-agents/\(agentID)/stop",
        body: [:],
        successMessage: "Stopped the terminal agent directly."
      )
    case "codex":
      return try request(
        path: "/v1/managed-agents/\(agentID)/interrupt",
        body: [:],
        successMessage: "Interrupted the Codex agent directly."
      )
    case "acp":
      return try request(
        method: "DELETE",
        path: "/v1/managed-agents/\(agentID)",
        successMessage: "Stopped the ACP agent directly."
      )
    case let kind?:
      throw MobileRemoteDaemonSyncError.unsupportedAgentKind(kind)
    case nil:
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
  }

  private static func agentPromptRequest(
    _ command: MobileCommandRecord,
    agentKind: String?
  ) throws -> MobileRemoteDaemonCommandRequest {
    let agentID = try command.remoteRequiredAgentID().remotePathComponent()
    let prompt = try command.remoteRequiredPayload("prompt")
    switch agentKind {
    case "terminal":
      let submittedPrompt = prompt.hasSuffix("\n") ? prompt : "\(prompt)\n"
      return try request(
        path: "/v1/managed-agents/\(agentID)/input",
        body: ["input": ["type": "text", "text": submittedPrompt]],
        successMessage: "Prompted the terminal agent directly."
      )
    case "codex":
      return try request(
        path: "/v1/managed-agents/\(agentID)/steer",
        body: ["prompt": prompt],
        successMessage: "Steered the Codex agent directly."
      )
    case "acp":
      return try request(
        path: "/v1/managed-agents/\(agentID)/prompt",
        body: ["prompt": prompt],
        successMessage: "Prompted the ACP agent directly."
      )
    case let kind?:
      throw MobileRemoteDaemonSyncError.unsupportedAgentKind(kind)
    case nil:
      throw MobileRemoteDaemonSyncError.invalidResponse
    }
  }

  private static func commonAgentStartBody(
    _ command: MobileCommandRecord
  ) throws -> [String: Any] {
    var body: [String: Any] = [
      "role": command.remoteOptionalPayload("role") ?? "worker",
      "capabilities": command.remoteCSVPayload("capabilities"),
      "allow_custom_model": try command.remoteBoolPayload("allowCustomModel") ?? false,
    ]
    body.add("fallback_role", command.remoteOptionalPayload("fallbackRole"))
    body.add("name", command.remoteOptionalPayload("name"))
    body.add("prompt", command.remoteOptionalPayload("prompt"))
    body.add("project_dir", command.remoteOptionalPayload("projectDir"))
    body.add("persona", command.remoteOptionalPayload("persona"))
    body.add("task_id", command.target.taskID?.remoteTrimmed)
    body.add("board_item_id", command.remoteOptionalPayload("boardItemID"))
    body.add("workflow_execution_id", command.remoteOptionalPayload("workflowExecutionID"))
    body.add("model", command.remoteOptionalPayload("model"))
    body.add("effort", command.remoteOptionalPayload("effort"))
    return body
  }

  private static func agentFamily(_ command: MobileCommandRecord, agent: String) throws -> String {
    if let family = command.remoteOptionalPayload("family") {
      guard ["terminal", "codex", "acp"].contains(family.lowercased()) else {
        throw MobileRemoteDaemonSyncError.invalidCommand("unknown agent family: \(family)")
      }
      return family.lowercased()
    }
    let normalized = agent.lowercased()
    if normalized.hasPrefix("terminal:") || normalized.hasPrefix("tui:") {
      return "terminal"
    }
    if normalized.hasPrefix("acp:") {
      return "acp"
    }
    if ["codex", "codex-native", "codex-run"].contains(normalized) {
      return "codex"
    }
    if ["claude", "codex", "gemini", "copilot", "vibe", "opencode"].contains(normalized) {
      return "terminal"
    }
    return "acp"
  }

  private static func terminalRuntime(_ command: MobileCommandRecord, agent: String) -> String {
    if let runtime = command.remoteOptionalPayload("runtime") {
      return runtime
    }
    let normalized = agent.lowercased()
    for prefix in ["terminal:", "tui:"] where normalized.hasPrefix(prefix) {
      return String(normalized.dropFirst(prefix.count))
    }
    return normalized
  }
}
