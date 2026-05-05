import Foundation
import HarnessMonitorKit

struct TimelineFeatureContext: Sendable {
  let now: Date
  let signalsByID: [String: SessionSignalRecord]
  let sessionID: String

  static let empty = TimelineFeatureContext(now: .distantPast, signalsByID: [:], sessionID: "")
}
