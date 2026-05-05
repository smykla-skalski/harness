import Foundation
import HarnessMonitorKit

struct TimelineFeatureContext: Sendable {
  let now: Date
  let signalsByID: [String: SessionSignalRecord]
  let sessionID: String

  static var empty: Self { Self(now: .now, signalsByID: [:], sessionID: "") }
}
