import Foundation
import SwiftData

/// Historical V13 schema: an additive managed-agent side-table keyed by
/// `(sessionId, agentId)`. This exact model must remain available so staged
/// migration can recognize stores created by the earlier V13 build.
extension HarnessMonitorSchemaV13 {
  @Model
  final class CachedAgentManagedMetadata {
    #Index<CachedAgentManagedMetadata>([\.sessionId, \.agentId])
    #Unique<CachedAgentManagedMetadata>([\.sessionId, \.agentId])

    var sessionId: String
    var agentId: String
    var managedAgentID: String
    var managedAgentKindRaw: String
    var updatedAt: Date

    init(
      sessionId: String,
      agentId: String,
      managedAgentID: String,
      managedAgentKindRaw: String,
      updatedAt: Date = .now
    ) {
      self.sessionId = sessionId
      self.agentId = agentId
      self.managedAgentID = managedAgentID
      self.managedAgentKindRaw = managedAgentKindRaw
      self.updatedAt = updatedAt
    }
  }
}
