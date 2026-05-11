import Foundation
import SwiftData

/// V11 adds a dedicated transcript side-table so session-window and selected-session
/// ACP transcript rows can be cached independently from the general timeline window.
/// The row is keyed by `(sessionId, entryId)` and mirrors the normalized `TimelineEntry`
/// payload so transcript ownership stays explicit without mutating the V6 session graph.
extension HarnessMonitorSchemaV11 {
  @Model
  final class CachedSessionTranscriptEntry {
    #Index<CachedSessionTranscriptEntry>([\.sessionId, \.recordedAt])
    #Unique<CachedSessionTranscriptEntry>([\.sessionId, \.entryId])

    var sessionId: String
    var entryId: String
    var recordedAt: String
    var kind: String
    var agentId: String?
    var taskId: String?
    var summary: String
    var payloadData: Data
    var updatedAt: Date

    init(
      sessionId: String,
      entryId: String,
      recordedAt: String,
      kind: String,
      agentId: String?,
      taskId: String?,
      summary: String,
      payloadData: Data,
      updatedAt: Date = .now
    ) {
      self.sessionId = sessionId
      self.entryId = entryId
      self.recordedAt = recordedAt
      self.kind = kind
      self.agentId = agentId
      self.taskId = taskId
      self.summary = summary
      self.payloadData = payloadData
      self.updatedAt = updatedAt
    }
  }
}
