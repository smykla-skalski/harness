import Foundation
import HarnessMonitorKit

struct TimelineFeatureContext: Sendable {
  let now: Date
  let signalsByID: [String: SessionSignalRecord]
  let sessionID: String

  static let empty = Self(now: .distantPast, signalsByID: [:], sessionID: "")
}
