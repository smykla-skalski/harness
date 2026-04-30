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
    let isError = event.boolValue(for: "is_error") ?? false
    let entryKind: String
    switch type {
    case "tool_invocation":
      entryKind = "tool_invocation"
    case "tool_result", "tool_result_error":
      entryKind = isError || type == "tool_result_error" ? "tool_result_error" : "tool_result"
    default:
      return nil
    }

    let toolName = event.stringValue(for: "tool_name") ?? "Tool"
    let acpAgentId = toolCallMetadata?.acpAgentId ?? acpID
    let fallbackAgentID = agent.isEmpty ? acpID : agent
    let agentId =
      if let metadataAgentID = toolCallMetadata?.agentId,
        metadataAgentID != acpID || agent.isEmpty
      {
        metadataAgentID
      } else {
        fallbackAgentID
      }
    let summaryActor =
      if let metadataDisplayName = toolCallMetadata?.displayName,
        metadataDisplayName != acpID || agent.isEmpty
      {
        metadataDisplayName
      } else {
        fallbackAgentID
      }
    let status = Self.toolCallStatus(for: entryKind)
    let summary: String =
      switch entryKind {
      case "tool_invocation":
        "\(summaryActor) invoked \(toolName)"
      case "tool_result_error":
        "\(summaryActor) received an error from \(toolName)"
      default:
        "\(summaryActor) received a result from \(toolName)"
      }

    return TimelineEntry(
      entryId: "acp-\(agentId)-\(entryKind)-\(sequence)",
      recordedAt: timestamp ?? fallbackRecordedAt,
      kind: entryKind,
      sessionId: sessionId,
      agentId: agentId,
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": kind,
        "tool_call_timeline": .object([
          "tool_call_id": event["invocation_id"] ?? .null,
          "tool_name": .string(toolName),
          "status": .string(status),
          "acp_agent_id": .string(acpAgentId),
          "agent_id": .string(agentId),
          "agent_display_name": .string(summaryActor),
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
