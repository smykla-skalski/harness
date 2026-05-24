import Foundation

/// UI-side projection types for OpenRouter sessions.
///
/// OpenRouter no longer ships a daemon-side managed-agent family. The daemon
/// dispatches OpenRouter through the generic ACP managed-agent surface using
/// the catalog descriptor `"openrouter"`. The Swift `OpenRouterRunSnapshot` is
/// therefore a Monitor-only projection layered on top of `AcpAgentSnapshot`,
/// enriched with model/transcript fields the store accumulates from the daemon
/// push event stream.

public enum OpenRouterRunStatus: String, Codable, Sendable {
  case pending
  case streaming
  case idle
  case cancelled
  case failed

  public var title: String {
    switch self {
    case .pending:
      "Pending"
    case .streaming:
      "Streaming"
    case .idle:
      "Idle"
    case .cancelled:
      "Cancelled"
    case .failed:
      "Failed"
    }
  }

  public var isActive: Bool {
    switch self {
    case .pending, .streaming:
      true
    case .idle, .cancelled, .failed:
      false
    }
  }

  /// Derive an OpenRouter UI status from an ACP agent's lifecycle state.
  public init(acp status: AgentStatus, disconnect: AgentDisconnectReason?) {
    switch status {
    case .active, .awaitingReview:
      self = .streaming
    case .idle:
      self = .idle
    case .disconnected:
      switch disconnect?.kind {
      case "user_cancelled":
        self = .cancelled
      case "daemon_shutdown", "unknown", .none:
        self = .cancelled
      default:
        self = .failed
      }
    case .removed:
      self = .cancelled
    }
  }
}

/// View model for a single OpenRouter session.
///
/// `runId` carries the same value as the underlying `AcpAgentSnapshot.acpId`,
/// so transport calls on this projection map directly to ACP managed-agent
/// routes (e.g. `stopManagedAcpAgent`, `resolveManagedAcpPermission`).
public struct OpenRouterRunSnapshot: Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let sessionAgentId: String?
  public let displayName: String
  public let model: String
  public let status: OpenRouterRunStatus
  public let latestMessage: String?
  public let latestReasoning: String?
  public let finalMessage: String?
  public let error: String?
  public let turnCount: UInt32
  public let pendingPermissionBatches: [AcpPermissionBatch]
  public let createdAt: String
  public let updatedAt: String

  public init(
    runId: String,
    sessionId: String,
    sessionAgentId: String? = nil,
    displayName: String,
    model: String,
    status: OpenRouterRunStatus,
    latestMessage: String? = nil,
    latestReasoning: String? = nil,
    finalMessage: String? = nil,
    error: String? = nil,
    turnCount: UInt32,
    pendingPermissionBatches: [AcpPermissionBatch] = [],
    createdAt: String,
    updatedAt: String
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.sessionAgentId = sessionAgentId
    self.displayName = displayName
    self.model = model
    self.status = status
    self.latestMessage = latestMessage
    self.latestReasoning = latestReasoning
    self.finalMessage = finalMessage
    self.error = error
    self.turnCount = turnCount
    self.pendingPermissionBatches = pendingPermissionBatches
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var id: String { runId }
  public var managedAgentID: String { runId }
  public var sessionAgentID: String? { sessionAgentId }
}

extension OpenRouterRunSnapshot {
  /// Project an `AcpAgentSnapshot` into an OpenRouter run snapshot.
  ///
  /// `model` and `displayName` are not carried by the daemon's ACP snapshot,
  /// so the store tracks them per run id from the original start request.
  public init(
    acp: AcpAgentSnapshot,
    model: String,
    displayName: String? = nil,
    latestMessage: String? = nil,
    latestReasoning: String? = nil,
    finalMessage: String? = nil,
    error: String? = nil,
    turnCount: UInt32 = 0
  ) {
    self.init(
      runId: acp.acpId,
      sessionId: acp.sessionId,
      sessionAgentId: acp.sessionAgentID,
      displayName: displayName ?? acp.displayName,
      model: model,
      status: OpenRouterRunStatus(acp: acp.status, disconnect: acp.disconnectReason),
      latestMessage: latestMessage,
      latestReasoning: latestReasoning,
      finalMessage: finalMessage,
      error: error ?? acp.stderrTail,
      turnCount: turnCount,
      pendingPermissionBatches: acp.pendingPermissionBatches,
      createdAt: acp.createdAt,
      updatedAt: acp.updatedAt
    )
  }
}

public struct OpenRouterModelEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let contextLength: UInt64?
  public let supportedParameters: [String]

  public init(
    id: String,
    name: String? = nil,
    contextLength: UInt64? = nil,
    supportedParameters: [String] = []
  ) {
    self.id = id
    self.name = name
    self.contextLength = contextLength
    self.supportedParameters = supportedParameters
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    contextLength = try container.decodeIfPresent(UInt64.self, forKey: .contextLength)
    supportedParameters =
      try container.decodeIfPresent([String].self, forKey: .supportedParameters) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case contextLength
    case supportedParameters
  }
}

public enum OpenRouterModelCatalogSource: String, Codable, Sendable {
  case live
  case cache
  case fallback
}

public struct OpenRouterModelCatalog: Codable, Equatable, Sendable {
  public let models: [OpenRouterModelEntry]
  public let fetchedAt: String
  public let source: OpenRouterModelCatalogSource

  public init(
    models: [OpenRouterModelEntry],
    fetchedAt: String,
    source: OpenRouterModelCatalogSource
  ) {
    self.models = models
    self.fetchedAt = fetchedAt
    self.source = source
  }
}
