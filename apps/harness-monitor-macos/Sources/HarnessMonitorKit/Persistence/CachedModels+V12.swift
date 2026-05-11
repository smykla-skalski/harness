import Foundation
import SwiftData

/// V12 keeps the dedicated transcript side-table and adds persisted provenance so
/// cache reloads can distinguish direct ACP transcript rows from timeline-derived
/// fallbacks. Legacy V11 rows migrate with `.cache` provenance until a live refresh
/// rewrites them with a stronger source.
extension HarnessMonitorSchemaV12 {
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
    var sourceRaw: String
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
      sourceRaw: String = HarnessMonitorSessionWindowTranscriptSource.cache.rawValue,
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
      self.sourceRaw = sourceRaw
      self.updatedAt = updatedAt
    }
  }
}

typealias CachedSessionTranscriptEntry = HarnessMonitorSchemaV12.CachedSessionTranscriptEntry
