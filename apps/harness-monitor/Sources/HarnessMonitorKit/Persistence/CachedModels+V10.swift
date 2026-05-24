import Foundation
import SwiftData

extension HarnessMonitorSchemaV10 {
  // V10 layers tab-grouping fields onto the V9 CachedSessionWindowState so
  // session windows that were tabbed together at quit can be re-merged at
  // launch. All three new fields are optional: SwiftData's lightweight
  // migration cannot fill non-optional defaults on existing rows, and the
  // call sites already treat nil as "not part of a tab group / not the
  // foreground tab" when reading.
  @Model
  final class CachedSessionWindowState {
    #Index<CachedSessionWindowState>([\.sessionId])
    #Unique<CachedSessionWindowState>([\.sessionId])

    var sessionId: String
    var wasOpenAtQuit: Bool
    var updatedAt: Date
    var tabGroupOrdinal: Int?
    var tabPosition: Int?
    var wasForegroundTab: Bool?

    init(
      sessionId: String,
      wasOpenAtQuit: Bool = false,
      updatedAt: Date = .now,
      tabGroupOrdinal: Int? = nil,
      tabPosition: Int? = nil,
      wasForegroundTab: Bool? = nil
    ) {
      self.sessionId = sessionId
      self.wasOpenAtQuit = wasOpenAtQuit
      self.updatedAt = updatedAt
      self.tabGroupOrdinal = tabGroupOrdinal
      self.tabPosition = tabPosition
      self.wasForegroundTab = wasForegroundTab
    }
  }
}

typealias CachedSessionWindowState = HarnessMonitorSchemaV10.CachedSessionWindowState
