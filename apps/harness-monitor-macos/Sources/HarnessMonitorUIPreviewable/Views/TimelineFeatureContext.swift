import Foundation
import HarnessMonitorKit

struct TimelineFeatureContext: Sendable {
  let now: Date
  let signalsByID: [String: SessionSignalRecord]

  static var empty: Self { Self(now: .now, signalsByID: [:]) }
}
