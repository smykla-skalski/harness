import Foundation
import SwiftData

/// JSONL exporter for `SupervisorEvent` and `Decision` rows.
///
/// The exporter opens the live SwiftData store on demand, fetches rows in batches, and writes one
/// JSON object per line so large audit logs do not need to be buffered in memory.
public enum SupervisorAuditExporter {
  public static func exportEvents(
    toURL url: URL,
    filter: String? = nil,
    modelContainer: ModelContainer? = nil
  ) async throws {
    try await export(
      toURL: url,
      filter: filter,
      modelContainer: modelContainer,
      fetchBatch: fetchEvents,
      encode: { try JSONEncoder.supervisorAudit.encode(SupervisorEventLine(event: $0)) }
    )
  }

  public static func exportDecisions(
    toURL url: URL,
    filter: String? = nil,
    modelContainer: ModelContainer? = nil
  ) async throws {
    try await export(
      toURL: url,
      filter: filter,
      modelContainer: modelContainer,
      fetchBatch: fetchDecisions,
      encode: { try JSONEncoder.supervisorAudit.encode(DecisionLine(decision: $0)) }
    )
  }

  private static func export<Row>(
    toURL url: URL,
    filter: String?,
    modelContainer: ModelContainer?,
    fetchBatch: (ModelContext, Int, Int) throws -> [Row],
    encode: (Row) throws -> Data
  ) async throws {
    let container = try modelContainer ?? HarnessMonitorModelContainer.live(using: .current)
    let context = ModelContext(container)
    let fileHandle = try openFileHandle(at: url)
    defer { try? fileHandle.close() }

    try writeRows(
      to: fileHandle,
      context: context,
      filter: filter,
      fetchBatch: fetchBatch,
      encode: encode
    )
  }

  private static func writeRows<Row>(
    to fileHandle: FileHandle,
    context: ModelContext,
    filter: String?,
    fetchBatch: (ModelContext, Int, Int) throws -> [Row],
    encode: (Row) throws -> Data
  ) throws {
    var offset = 0
    let batchSize = 256
    while true {
      let batch = try fetchBatch(context, offset, batchSize)
      guard !batch.isEmpty else { return }
      for row in batch {
        let line = try encode(row)
        guard passesFilter(line, filter: filter) else { continue }
        try fileHandle.write(contentsOf: line)
        try fileHandle.write(contentsOf: Data([0x0A]))
      }
      offset += batch.count
    }
  }

  private static func passesFilter(_ line: Data, filter: String?) -> Bool {
    guard let filter, !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return true
    }
    guard let string = String(data: line, encoding: .utf8) else { return false }
    return string.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private static func openFileHandle(at url: URL) throws -> FileHandle {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    return handle
  }

  private static func fetchEvents(
    _ context: ModelContext,
    _ offset: Int,
    _ limit: Int
  ) throws -> [SupervisorEvent] {
    var descriptor = FetchDescriptor<SupervisorEvent>(
      sortBy: [
        SortDescriptor(\.createdAt, order: .forward),
        SortDescriptor(\.id, order: .forward),
      ]
    )
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    return try context.fetch(descriptor)
  }

  private static func fetchDecisions(
    _ context: ModelContext,
    _ offset: Int,
    _ limit: Int
  ) throws -> [Decision] {
    var descriptor = FetchDescriptor<Decision>(
      sortBy: [
        SortDescriptor(\.createdAt, order: .forward),
        SortDescriptor(\.id, order: .forward),
      ]
    )
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit
    return try context.fetch(descriptor)
  }
}

private struct SupervisorEventLine: Encodable {
  enum CodingKeys: String, CodingKey {
    case createdAt
    case id
    case kind
    case payloadJSON
    case ruleID
    case severityRaw
    case tickID
  }

  let createdAt: Date
  let id: String
  let kind: String
  let payloadJSON: String
  let ruleID: String?
  let severityRaw: String?
  let tickID: String

  init(event: SupervisorEvent) {
    createdAt = event.createdAt
    id = event.id
    kind = event.kind
    payloadJSON = event.payloadJSON
    ruleID = event.ruleID
    severityRaw = event.severityRaw
    tickID = event.tickID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(payloadJSON, forKey: .payloadJSON)
    try container.encodeNullable(ruleID, forKey: .ruleID)
    try container.encodeNullable(severityRaw, forKey: .severityRaw)
    try container.encode(tickID, forKey: .tickID)
  }
}

private struct DecisionLine: Encodable {
  enum CodingKeys: String, CodingKey {
    case agentID
    case contextJSON
    case createdAt
    case id
    case resolutionJSON
    case ruleID
    case severityRaw
    case sessionID
    case snoozedUntil
    case statusRaw
    case suggestedActionsJSON
    case summary
    case taskID
  }

  let agentID: String?
  let contextJSON: String
  let createdAt: Date
  let id: String
  let resolutionJSON: String?
  let ruleID: String
  let severityRaw: String
  let sessionID: String?
  let snoozedUntil: Date?
  let statusRaw: String
  let suggestedActionsJSON: String
  let summary: String
  let taskID: String?

  init(decision: Decision) {
    agentID = decision.agentID
    contextJSON = decision.contextJSON
    createdAt = decision.createdAt
    id = decision.id
    resolutionJSON = decision.resolutionJSON
    ruleID = decision.ruleID
    severityRaw = decision.severityRaw
    sessionID = decision.sessionID
    snoozedUntil = decision.snoozedUntil
    statusRaw = decision.statusRaw
    suggestedActionsJSON = decision.suggestedActionsJSON
    summary = decision.summary
    taskID = decision.taskID
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeNullable(agentID, forKey: .agentID)
    try container.encode(contextJSON, forKey: .contextJSON)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(id, forKey: .id)
    try container.encodeNullable(resolutionJSON, forKey: .resolutionJSON)
    try container.encode(ruleID, forKey: .ruleID)
    try container.encode(severityRaw, forKey: .severityRaw)
    try container.encodeNullable(sessionID, forKey: .sessionID)
    try container.encodeNullable(snoozedUntil, forKey: .snoozedUntil)
    try container.encode(statusRaw, forKey: .statusRaw)
    try container.encode(suggestedActionsJSON, forKey: .suggestedActionsJSON)
    try container.encode(summary, forKey: .summary)
    try container.encodeNullable(taskID, forKey: .taskID)
  }
}

extension JSONEncoder {
  static var supervisorAudit: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}

extension KeyedEncodingContainer {
  fileprivate mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
    if let value {
      try encode(value, forKey: key)
    } else {
      try encodeNil(forKey: key)
    }
  }
}
