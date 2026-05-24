import Foundation
import HarnessMonitorKit
import OSLog

actor SessionTimelinePresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private var cachedKey: SessionTimelineSectionPresentationCacheKey?
  private var cachedPresentation: SessionTimelineSectionPresentation = .empty
  private(set) var rebuildCount = 0

  func compute(
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
      let signpostID = Self.signposter.makeSignpostID()
      let interval = Self.signposter.beginInterval(
        "session_timeline.presentation.compute",
        id: signpostID,
        "session=\(input.sessionID, privacy: .public) entries=\(input.timeline.count, privacy: .public)"
      )
      defer {
        Self.signposter.endInterval(
          "session_timeline.presentation.compute",
          interval,
          "rows=\(self.cachedPresentation.rows.count, privacy: .public)"
        )
      }
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

  func waitForIdle() async {}
}

final class SessionTimelineSectionPresentationCache {
  private var cachedInput: SessionTimelineSectionPresentationInput?
  private var cachedPresentation: SessionTimelineSectionPresentation = .empty
  private(set) var rebuildCount = 0

  func presentation(
    _ input: SessionTimelineSectionPresentationInput
  ) -> SessionTimelineSectionPresentation {
    if cachedInput != input {
      cachedInput = input
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

struct SessionTimelineSectionPresentationInput: Equatable, Sendable {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [SessionTimelineDecisionInput]
  let signals: [SessionSignalRecord]
  let filters: SessionTimelineFilterState
  let isTimelineLoading: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let now: Date

  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [SessionTimelineDecisionInput],
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

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sessionID == rhs.sessionID
      && lhs.timeline == rhs.timeline
      && lhs.timelineWindow == rhs.timelineWindow
      && lhs.decisions == rhs.decisions
      && lhs.signals == rhs.signals
      && lhs.filters == rhs.filters
      && lhs.isTimelineLoading == rhs.isTimelineLoading
      && lhs.dateTimeConfiguration == rhs.dateTimeConfiguration
  }
}

private struct SessionTimelineSectionPresentationCacheKey: Equatable {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [SessionTimelineDecisionInput]
  let signals: [SignalSignature]
  let filters: SessionTimelineFilterState
  let isTimelineLoading: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [SessionTimelineDecisionInput],
    signals: [SessionSignalRecord],
    filters: SessionTimelineFilterState,
    isTimelineLoading: Bool,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    now: Date
  ) {
    self.sessionID = sessionID
    self.timeline = timeline
    self.timelineWindow = timelineWindow
    self.decisions = decisions
    self.signals = signals.map { SignalSignature(record: $0, now: now) }
    self.filters = filters
    self.isTimelineLoading = isTimelineLoading
    self.dateTimeConfiguration = dateTimeConfiguration
  }
}

struct SessionTimelinePresentationTaskKey: Equatable {
  let sessionID: String
  let timelineRevision: UInt64
  let timelineWindowRevision: UInt64
  let timelineFallbackSignature: SessionTimelineEntriesBoundarySignature
  let timelineWindowSignature: SessionTimelineWindowSignature?
  let decisionsRevision: Int
  let decisionsCount: Int
  let signalsRevision: UInt64
  let signalDeadlineGeneration: UInt64
  let filters: SessionTimelineFilterState
  let isTimelineLoading: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
}

struct SessionTimelineSignalDeadlineClockKey: Equatable {
  let pendingExpirations: [Date]

  init(signals: [SessionSignalRecord], now: Date = .now) {
    pendingExpirations =
      signals
      .compactMap { record -> Date? in
        guard record.status == .pending,
          let expires = record.expiresAtDate,
          expires > now
        else { return nil }
        return expires
      }
      .sorted()
  }

  var nextExpiration: Date? {
    pendingExpirations.first
  }
}

struct SessionTimelineEntriesBoundarySignature: Equatable {
  let count: Int
  let firstEntryID: String?
  let lastEntryID: String?
  let lastRecordedAt: String?
  let lastSummary: String?

  init(_ timeline: [TimelineEntry]) {
    count = timeline.count
    firstEntryID = timeline.first?.entryId
    lastEntryID = timeline.last?.entryId
    lastRecordedAt = timeline.last?.recordedAt
    lastSummary = timeline.last?.summary
  }
}

struct SessionTimelineWindowSignature: Equatable {
  let revision: Int64
  let totalCount: Int
  let windowStart: Int
  let windowEnd: Int
  let hasOlder: Bool
  let hasNewer: Bool

  init?(_ window: TimelineWindowResponse?) {
    guard let window else {
      return nil
    }
    revision = window.revision
    totalCount = window.totalCount
    windowStart = window.windowStart
    windowEnd = window.windowEnd
    hasOlder = window.hasOlder
    hasNewer = window.hasNewer
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
