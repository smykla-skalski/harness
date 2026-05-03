import HarnessMonitorKit
import SwiftUI

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

struct SessionTimelineContentIdentity: Hashable {
  let sessionID: String
}

enum SessionTimelinePresentationRetention {
  static func shouldRetainPreviousPresentation(
    previousPresentation: SessionTimelineSectionPresentation,
    previousInput: SessionTimelinePresentationInput,
    nextPresentation: SessionTimelineSectionPresentation,
    nextInput: SessionTimelinePresentationInput
  ) -> Bool {
    guard previousInput.sessionID == nextInput.sessionID else {
      return false
    }
    guard !previousPresentation.rows.isEmpty, nextPresentation.rows.isEmpty else {
      return false
    }
    return nextInput.isTimelineLoading || nextPresentation.showsEmptyState
  }

  static func resolved(
    previousPresentation: SessionTimelineSectionPresentation,
    previousInput: SessionTimelinePresentationInput,
    nextPresentation: SessionTimelineSectionPresentation,
    nextInput: SessionTimelinePresentationInput
  ) -> SessionTimelineSectionPresentation {
    if shouldRetainPreviousPresentation(
      previousPresentation: previousPresentation,
      previousInput: previousInput,
      nextPresentation: nextPresentation,
      nextInput: nextInput
    ) {
      return previousPresentation
    }
    return nextPresentation
  }
}

enum SessionTimelinePlaceholderShimmer {
  static let cycleDuration: TimeInterval = 1.8
  static let restingPhase: CGFloat = -0.6

  static func shouldAnimate(reduceMotion: Bool, placeholderCount: Int) -> Bool {
    !reduceMotion && placeholderCount > 0
  }

  static func phase(at date: Date = Date()) -> CGFloat {
    let elapsedInCycle = date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: cycleDuration)
    let cycleProgress = elapsedInCycle / cycleDuration
    return restingPhase + (CGFloat(cycleProgress) * 2.4)
  }
}

extension SessionCockpitTimelineSection {
  var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(sessionID: sessionID)
  }

  func loadWindow(_ request: TimelineWindowRequest) async {
    await store.loadSelectedTimelineWindow(request: request)
  }

  var actionHandler: any DecisionActionHandler {
    store.supervisorDecisionActionHandler()
  }
}
