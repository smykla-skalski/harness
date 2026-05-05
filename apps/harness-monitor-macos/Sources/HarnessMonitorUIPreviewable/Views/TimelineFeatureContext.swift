import Foundation
import HarnessMonitorKit

struct TimelineFeatureContext: Sendable {
  let now: Date
  let signalsByID: [String: SessionSignalRecord]
  // sessionID is unused by current features; reserved for future features that scope
  // signal queries or cancel/resend actions to the current session.
  let sessionID: String

  static var empty: Self { Self(now: .now, signalsByID: [:], sessionID: "") }
}
