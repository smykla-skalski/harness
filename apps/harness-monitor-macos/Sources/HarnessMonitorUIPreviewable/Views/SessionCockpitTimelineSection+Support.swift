import HarnessMonitorKit
import SwiftUI

enum SessionTimelinePlaceholderShimmer {
  static let cycleDuration: TimeInterval = 1.15
  private static let leadingPhase: CGFloat = -0.6
  private static let trailingPhase: CGFloat = 1.8

  static func shouldAnimate(reduceMotion: Bool, placeholderCount: Int) -> Bool {
    !reduceMotion && placeholderCount > 0
  }

  static func phase(at date: Date) -> CGFloat {
    let cycleProgress =
      date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: cycleDuration)
      / cycleDuration
    return leadingPhase + ((trailingPhase - leadingPhase) * cycleProgress)
  }

  static var restingPhase: CGFloat {
    0
  }
}

struct SessionTimelineContentIdentity: Hashable, Sendable {
  let sessionID: String
}

struct SessionTimelinePresentationInput: Equatable {
  let sessionID: String
  let timelineCount: Int
  let firstTimelineEntryID: String?
  let firstTimelineRecordedAt: String?
  let lastTimelineEntryID: String?
  let lastTimelineRecordedAt: String?
  let timelineWindowRevision: Int64?
  let timelineWindowStart: Int?
  let timelineWindowEnd: Int?
  let timelineWindowHasOlder: Bool
  let timelineWindowHasNewer: Bool
  let decisionCount: Int
  let firstDecisionID: String?
  let lastDecisionID: String?
  let isTimelineLoading: Bool
  let reduceMotion: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  static var empty: Self {
    Self(
      sessionID: "",
      timelineCount: 0,
      firstTimelineEntryID: nil,
      firstTimelineRecordedAt: nil,
      lastTimelineEntryID: nil,
      lastTimelineRecordedAt: nil,
      timelineWindowRevision: nil,
      timelineWindowStart: nil,
      timelineWindowEnd: nil,
      timelineWindowHasOlder: false,
      timelineWindowHasNewer: false,
      decisionCount: 0,
      firstDecisionID: nil,
      lastDecisionID: nil,
      isTimelineLoading: false,
      reduceMotion: false,
      dateTimeConfiguration: .default
    )
  }
}
