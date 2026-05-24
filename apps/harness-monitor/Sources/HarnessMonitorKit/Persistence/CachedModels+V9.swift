import Foundation
import SwiftData

extension HarnessMonitorSchemaV9 {
  @Model
  final class CachedSessionWindowState {
    #Index<CachedSessionWindowState>([\.sessionId])
    #Unique<CachedSessionWindowState>([\.sessionId])

    var sessionId: String
    var wasOpenAtQuit: Bool
    var updatedAt: Date

    init(
      sessionId: String,
      wasOpenAtQuit: Bool = false,
      updatedAt: Date = .now
    ) {
      self.sessionId = sessionId
      self.wasOpenAtQuit = wasOpenAtQuit
      self.updatedAt = updatedAt
    }
  }
}
