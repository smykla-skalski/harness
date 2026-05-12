import Foundation
import HarnessMonitorKit

@MainActor
final class SessionTimelineSectionPresentationCache {
  private var cachedKey: SessionTimelineSectionPresentationCacheKey?
  private var cachedPresentation: SessionTimelineSectionPresentation = .empty
  private(set) var rebuildCount = 0

  func presentation(
    _ input: SessionTimelineSectionPresentationInput
  ) -> SessionTimelineSectionPresentation {
    let key = SessionTimelineSectionPresentationCacheKey(
      sessionID: input.sessionID,
      timeline: input.timeline,
      timelineWindow: input.timelineWindow,
      decisions: input.decisions,
      signals: input.signals,
      filters: input.filters,
      isTimelineLoading: input.isTimelineLoading,
      dateTimeConfiguration: input.dateTimeConfiguration,
      now: input.now
    )
    if key != cachedKey {
      cachedKey = key
      cachedPresentation = SessionTimelineSectionPresentation(
        sessionID: input.sessionID,
        timeline: input.timeline,
        timelineWindow: input.timelineWindow,
        decisions: input.decisions,
        signals: input.signals,
        filters: input.filters,
        isTimelineLoading: input.isTimelineLoading,
        dateTimeConfiguration: input.dateTimeConfiguration,
        now: input.now
      )
      rebuildCount += 1
    }
    return cachedPresentation
  }
}

struct SessionTimelineSectionPresentationInput {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [Decision]
  let signals: [SessionSignalRecord]
  let filters: SessionTimelineFilterState
  let isTimelineLoading: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let now: Date

  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    signals: [SessionSignalRecord],
    filters: SessionTimelineFilterState,
    isTimelineLoading: Bool,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    now: Date = Date()
  ) {
    self.sessionID = sessionID
    self.timeline = timeline
    self.timelineWindow = timelineWindow
    self.decisions = decisions
    self.signals = signals
    self.filters = filters
    self.isTimelineLoading = isTimelineLoading
    self.dateTimeConfiguration = dateTimeConfiguration
    self.now = now
  }
}

private struct SessionTimelineSectionPresentationCacheKey: Equatable {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [DecisionSignature]
  let signals: [SignalSignature]
  let filters: SessionTimelineFilterState
  let isTimelineLoading: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    signals: [SessionSignalRecord],
    filters: SessionTimelineFilterState,
    isTimelineLoading: Bool,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    now: Date
  ) {
    self.sessionID = sessionID
    self.timeline = timeline
    self.timelineWindow = timelineWindow
    self.decisions = decisions.map(DecisionSignature.init(decision:))
    self.signals = signals.map { SignalSignature(record: $0, now: now) }
    self.filters = filters
    self.isTimelineLoading = isTimelineLoading
    self.dateTimeConfiguration = dateTimeConfiguration
  }
}

private struct DecisionSignature: Equatable {
  let id: String
  let severityRaw: String
  let ruleID: String
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let summary: String
  let suggestedActionsJSON: String
  let createdAt: Date

  init(decision: Decision) {
    id = decision.id
    severityRaw = decision.severityRaw
    ruleID = decision.ruleID
    sessionID = decision.sessionID
    agentID = decision.agentID
    taskID = decision.taskID
    summary = decision.summary
    suggestedActionsJSON = decision.suggestedActionsJSON
    createdAt = decision.createdAt
  }
}

private struct SignalSignature: Equatable {
  let record: SessionSignalRecord
  let effectiveStatus: SessionSignalStatus

  init(record: SessionSignalRecord, now: Date) {
    self.record = record
    effectiveStatus = record.effectiveStatus(now: now)
  }
}
