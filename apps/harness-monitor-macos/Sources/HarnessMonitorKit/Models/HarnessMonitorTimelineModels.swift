import Foundation

public struct TimelineEntry: Codable, Equatable, Identifiable, Sendable {
  public let entryId: String
  public let recordedAt: String
  public let kind: String
  public let sessionId: String
  public let agentId: String?
  public let taskId: String?
  public let summary: String
  public let payload: JSONValue

  public var id: String { entryId }
}

public struct TimelineCursor: Codable, Equatable, Sendable {
  public let recordedAt: String
  public let entryId: String

  public init(recordedAt: String, entryId: String) {
    self.recordedAt = recordedAt
    self.entryId = entryId
  }
}

public struct TimelineWindowRequest: Codable, Equatable, Sendable {
  public let scope: TimelineScope?
  public let limit: Int?
  public let before: TimelineCursor?
  public let after: TimelineCursor?
  public let knownRevision: Int64?

  public init(
    scope: TimelineScope? = nil,
    limit: Int? = nil,
    before: TimelineCursor? = nil,
    after: TimelineCursor? = nil,
    knownRevision: Int64? = nil
  ) {
    self.scope = scope
    self.limit = limit
    self.before = before
    self.after = after
    self.knownRevision = knownRevision
  }

  public static func latest(
    limit: Int,
    scope: TimelineScope = .summary,
    knownRevision: Int64? = nil
  ) -> Self {
    Self(
      scope: scope,
      limit: limit,
      knownRevision: knownRevision
    )
  }
}

public struct TimelineWindowResponse: Codable, Equatable, Sendable {
  public let revision: Int64
  public let totalCount: Int
  public let windowStart: Int
  public let windowEnd: Int
  public let hasOlder: Bool
  public let hasNewer: Bool
  public let oldestCursor: TimelineCursor?
  public let newestCursor: TimelineCursor?
  public let entries: [TimelineEntry]?
  public let unchanged: Bool

  public init(
    revision: Int64,
    totalCount: Int,
    windowStart: Int,
    windowEnd: Int,
    hasOlder: Bool,
    hasNewer: Bool,
    oldestCursor: TimelineCursor?,
    newestCursor: TimelineCursor?,
    entries: [TimelineEntry]?,
    unchanged: Bool
  ) {
    self.revision = revision
    self.totalCount = totalCount
    self.windowStart = windowStart
    self.windowEnd = windowEnd
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
    self.oldestCursor = oldestCursor
    self.newestCursor = newestCursor
    self.entries = entries
    self.unchanged = unchanged
  }

  public var pageSize: Int {
    max(1, windowEnd - windowStart)
  }

  public var metadataOnly: Self {
    Self(
      revision: revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: nil,
      unchanged: unchanged
    )
  }

  public func replacingEntries(_ entries: [TimelineEntry]?) -> Self {
    Self(
      revision: revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: hasNewer,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: entries,
      unchanged: unchanged
    )
  }

  public static func fallbackMetadata(for entries: [TimelineEntry]) -> Self {
    Self(
      revision: 0,
      totalCount: entries.count,
      windowStart: 0,
      windowEnd: entries.count,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: entries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: entries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
  }
}

public struct LogLevelResponse: Codable, Equatable, Sendable {
  public let level: String
  public let filter: String

  public init(level: String, filter: String) {
    self.level = level
    self.filter = filter
  }
}

public struct SetLogLevelRequest: Codable, Equatable, Sendable {
  public let level: String

  public init(level: String) {
    self.level = level
  }
}

public struct SessionsUpdatedPayload: Codable, Equatable, Sendable {
  public let projects: [ProjectSummary]
  public let sessions: [SessionSummary]
}

public struct SessionUpdatedPayload: Codable, Equatable, Sendable {
  public let detail: SessionDetail
  public let timeline: [TimelineEntry]?
  public let extensionsPending: Bool?
}

/// Wire-format ACP event envelope received from the daemon.
///
/// UI-0 contract:
/// - This payload is already the canonical daemon boundary for ACP timeline updates; the planned
///   UI-7 coalescer is strictly an in-process Swift concern and must not require a wire change.
/// - `rawCount` records how many upstream daemon events were folded into this push so overflow
///   logs can describe loss in terms of dropped raw events instead of opaque UI rows.
/// - `events` preserve daemon emission order. Any future coalescer may drop oldest entries under
///   pressure, but retained entries must keep this relative order.
public struct AcpEventBatchPayload: Codable, Equatable, Sendable {
  public let acpId: String
  public let sessionId: String
  public let rawCount: Int
  public let events: [AcpConversationEvent]

  public init(
    acpId: String,
    sessionId: String,
    rawCount: Int,
    events: [AcpConversationEvent]
  ) {
    self.acpId = acpId
    self.sessionId = sessionId
    self.rawCount = rawCount
    self.events = events
  }
}

public struct AcpConversationEvent: Codable, Equatable, Sendable {
  public let timestamp: String?
  public let sequence: UInt64
  public let kind: JSONValue
  public let agent: String
  public let sessionId: String

  public init(
    timestamp: String?,
    sequence: UInt64,
    kind: JSONValue,
    agent: String,
    sessionId: String
  ) {
    self.timestamp = timestamp
    self.sequence = sequence
    self.kind = kind
    self.agent = agent
    self.sessionId = sessionId
  }
}

struct AcpToolCallTimelineMetadata: Equatable, Sendable {
  let acpAgentId: String
  let agentId: String
  let displayName: String
  let capabilityTags: [String]
}

extension AcpEventBatchPayload {
  /// Materialise timeline rows from the raw daemon payload without mutating ordering semantics.
  ///
  /// UI-0 contract: this transform is payload-only. Any future buffering, overflow, or
  /// `drop-oldest` policy belongs after decode and before store mutation so the wire contract
  /// stays stable across UI-only refactors.
  public func timelineEntries(
    fallbackRecordedAt: String
  ) -> [TimelineEntry] {
    timelineEntries(
      fallbackRecordedAt: fallbackRecordedAt,
      toolCallMetadata: nil
    )
  }

  func timelineEntries(
    fallbackRecordedAt: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> [TimelineEntry] {
    events
      .filter { $0.sessionId == sessionId }
      .compactMap { event in
        event.timelineEntry(
          acpID: acpId,
          fallbackRecordedAt: fallbackRecordedAt,
          toolCallMetadata: toolCallMetadata
        )
      }
  }
}

extension AcpConversationEvent {
  fileprivate func timelineEntry(
    acpID: String,
    fallbackRecordedAt: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> TimelineEntry? {
    guard case .object(let event) = kind,
      let type = event.stringValue(for: "type")
    else {
      return nil
    }
    let identity = Self.timelineIdentity(
      acpID: acpID,
      fallbackAgent: agent,
      toolCallMetadata: toolCallMetadata
    )
    let recordedAt = timestamp ?? fallbackRecordedAt

    switch type {
    case "user_prompt":
      return transcriptTimelineEntry(
        entryKind: "user_prompt",
        summary: Self.transcriptSummary(
          from: event["content"],
          fallback: "Prompt submitted"
        ),
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "assistant_text":
      return transcriptTimelineEntry(
        entryKind: "assistant_text",
        summary: Self.transcriptSummary(
          from: event["content"],
          fallback: "Assistant response"
        ),
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "error":
      return transcriptTimelineEntry(
        entryKind: "agent_error",
        summary:
          "\(identity.summaryActor) error: \(event.stringValue(for: "message") ?? "Unknown error")",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "signal_received":
      let signalID = event.stringValue(for: "signal_id") ?? "signal"
      let command = event.stringValue(for: "command") ?? "unknown"
      return transcriptTimelineEntry(
        entryKind: "signal_received",
        summary: "\(identity.summaryActor) picked up \(signalID) (\(command))",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "state_change":
      let from = event.stringValue(for: "from") ?? "unknown"
      let to = event.stringValue(for: "to") ?? "unknown"
      return transcriptTimelineEntry(
        entryKind: "agent_state_change",
        summary: "\(identity.summaryActor) state changed \(from) -> \(to)",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "file_modification":
      let operation = event.stringValue(for: "operation") ?? "modified"
      let path = event.stringValue(for: "path") ?? "file"
      return transcriptTimelineEntry(
        entryKind: "file_modification",
        summary: "\(identity.summaryActor) \(operation) \(path)",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "session_marker":
      let marker = event.stringValue(for: "marker") ?? "session"
      return transcriptTimelineEntry(
        entryKind: "agent_session_marker",
        summary: "\(identity.summaryActor) marked \(marker)",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "watchdog_state":
      let from = event.stringValue(for: "from") ?? "unknown"
      let to = event.stringValue(for: "to") ?? "unknown"
      return transcriptTimelineEntry(
        entryKind: "agent_watchdog_state",
        summary: "\(identity.summaryActor) watchdog \(from) -> \(to)",
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "permission_asked":
      let tool = event.stringValue(for: "tool") ?? "tool"
      let scope = event.stringValue(for: "scope") ?? ""
      let summary =
        scope.isEmpty
        ? "\(identity.summaryActor) asked for permission on \(tool)"
        : "\(identity.summaryActor) asked for permission on \(tool) (\(scope))"
      return transcriptTimelineEntry(
        entryKind: "agent_permission_asked",
        summary: summary,
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "context_injected":
      let actor = event.stringValue(for: "actor") ?? "system"
      let detail = event.stringValue(for: "summary") ?? ""
      let summary =
        detail.isEmpty
        ? "\(identity.summaryActor) received context from \(actor)"
        : "\(identity.summaryActor) received context from \(actor): \(detail)"
      return transcriptTimelineEntry(
        entryKind: "agent_context_injected",
        summary: summary,
        kind: kind,
        recordedAt: recordedAt,
        identity: identity
      )
    case "tool_invocation", "tool_result", "tool_result_error":
      break
    default:
      return nil
    }

    let isError = event.boolValue(for: "is_error") ?? false
    let entryKind =
      if type == "tool_invocation" {
        "tool_invocation"
      } else if isError || type == "tool_result_error" {
        "tool_result_error"
      } else {
        "tool_result"
      }
    let toolName = event.stringValue(for: "tool_name") ?? "Tool"
    let status = Self.toolCallStatus(for: entryKind)
    let summary: String =
      switch entryKind {
      case "tool_invocation":
        "\(identity.summaryActor) invoked \(toolName)"
      case "tool_result_error":
        "\(identity.summaryActor) received an error from \(toolName)"
      default:
        "\(identity.summaryActor) received a result from \(toolName)"
      }

    return TimelineEntry(
      entryId: "acp-\(identity.agentId)-\(entryKind)-\(sequence)",
      recordedAt: recordedAt,
      kind: entryKind,
      sessionId: sessionId,
      agentId: identity.agentId,
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": kind,
        "acp_timeline_identity": Self.acpTimelineIdentityPayload(
          from: identity,
          sequence: sequence
        ),
        "tool_call_timeline": .object([
          "tool_call_id": event["invocation_id"] ?? .null,
          "tool_name": .string(toolName),
          "status": .string(status),
          "acp_agent_id": .string(identity.acpAgentId),
          "agent_id": .string(identity.agentId),
          "agent_display_name": .string(identity.summaryActor),
          "capability_tags": .array(
            (toolCallMetadata?.capabilityTags ?? []).map(JSONValue.string)
          ),
          "sequence": .number(Double(sequence)),
          "stop_reason": event["stop_reason"] ?? .null,
        ]),
      ])
    )
  }

  private static func toolCallStatus(for entryKind: String) -> String {
    switch entryKind {
    case "tool_invocation":
      "started"
    case "tool_result_error":
      "failed"
    default:
      "completed"
    }
  }

  private func transcriptTimelineEntry(
    entryKind: String,
    summary: String,
    kind: JSONValue,
    recordedAt: String,
    identity: (acpAgentId: String, agentId: String, summaryActor: String)
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: "acp-\(identity.agentId)-\(entryKind)-\(sequence)",
      recordedAt: recordedAt,
      kind: entryKind,
      sessionId: sessionId,
      agentId: identity.agentId,
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": kind,
        "acp_timeline_identity": Self.acpTimelineIdentityPayload(
          from: identity,
          sequence: sequence
        ),
      ])
    )
  }

  private static func transcriptSummary(
    from value: JSONValue?,
    fallback: String
  ) -> String {
    guard case .string(let content)? = value else {
      return fallback
    }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private static func timelineIdentity(
    acpID: String,
    fallbackAgent: String,
    toolCallMetadata: AcpToolCallTimelineMetadata?
  ) -> (acpAgentId: String, agentId: String, summaryActor: String) {
    let acpAgentId = toolCallMetadata?.acpAgentId ?? acpID
    let fallbackAgentID = fallbackAgent.isEmpty ? acpID : fallbackAgent
    let agentId =
      if let metadataAgentID = toolCallMetadata?.agentId,
        metadataAgentID != acpID || fallbackAgent.isEmpty
      {
        metadataAgentID
      } else {
        fallbackAgentID
      }
    let summaryActor =
      if let metadataDisplayName = toolCallMetadata?.displayName,
        metadataDisplayName != acpID || fallbackAgent.isEmpty
      {
        metadataDisplayName
      } else {
        fallbackAgentID
      }
    return (acpAgentId, agentId, summaryActor)
  }

  private static func acpTimelineIdentityPayload(
    from identity: (acpAgentId: String, agentId: String, summaryActor: String),
    sequence: UInt64
  ) -> JSONValue {
    .object([
      "acp_agent_id": .string(identity.acpAgentId),
      "agent_id": .string(identity.agentId),
      "agent_display_name": .string(identity.summaryActor),
      "sequence": .number(Double(sequence)),
    ])
  }
}

public struct StreamEvent: Codable, Equatable, Identifiable, Sendable {
  public let event: String
  public let recordedAt: String
  public let sessionId: String?
  public let payload: JSONValue
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case event, recordedAt, sessionId, payload }

  public init(event: String, recordedAt: String, sessionId: String?, payload: JSONValue) {
    self.event = event
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.payload = payload
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.event == rhs.event && lhs.recordedAt == rhs.recordedAt
      && lhs.sessionId == rhs.sessionId && lhs.payload == rhs.payload
  }
}
