import Foundation
import OSLog
import SwiftUI

@testable import HarnessMonitorKit

struct ToolCallTimelineOverflowAnnouncement: Equatable, Sendable {
  let id: String
  let text: String
}

struct ToolCallTimelinePresentation: Equatable, Sendable {
  let sections: [ToolCallTimelineSection]

  var rows: [ToolCallTimelineRow] {
    sections.flatMap(\.rows)
  }

  static let empty = Self(sections: [])

  static func sections(for rows: [ToolCallTimelineRow]) -> [ToolCallTimelineSection] {
    var sections: [ToolCallTimelineSection] = []
    for row in rows {
      if let lastSection = sections.last,
        lastSection.canAppend(row)
      {
        sections[sections.count - 1].rows.append(row)
      } else {
        sections.append(ToolCallTimelineSection(firstRow: row))
      }
    }
    return sections
  }
}

struct ToolCallTimelineAnnouncementSnapshot: Equatable, Sendable {
  let rows: [ToolCallTimelineRow]
  let liveRowIDs: Set<String>
  let statusesByRowID: [String: ToolCallTimelineRow.Status]

  init(rows: [ToolCallTimelineRow], liveRowIDs: Set<String>) {
    self.rows = rows
    self.liveRowIDs = liveRowIDs
    statusesByRowID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
  }

  static let empty = Self(rows: [], liveRowIDs: [])
}

struct ToolCallTimelinePresentationInput: Equatable, Sendable {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  let scrollMetrics: ToolCallTimelineScrollMetrics
}

struct ToolCallTimelinePresentationTaskKey: Equatable {
  let entriesSignature: ToolCallTimelineEntriesBoundarySignature
  let liveAnnouncementRowIDsCount: Int
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  let scrollBucket: ToolCallTimelineVirtualizedScrollBucket

  init(
    entries: [TimelineEntry],
    liveAnnouncementRowIDs: Set<String>,
    overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?,
    scrollMetrics: ToolCallTimelineScrollMetrics
  ) {
    entriesSignature = ToolCallTimelineEntriesBoundarySignature(entries)
    liveAnnouncementRowIDsCount = liveAnnouncementRowIDs.count
    self.overflowNotice = overflowNotice
    scrollBucket = ToolCallTimelineVirtualizedLayout.scrollBucket(for: scrollMetrics)
  }
}

struct ToolCallTimelineEntriesBoundarySignature: Equatable {
  let count: Int
  let firstEntryID: String?
  let lastEntryID: String?
  let lastRecordedAt: String?
  let lastSummary: String?

  init(_ entries: [TimelineEntry]) {
    count = entries.count
    firstEntryID = entries.first?.entryId
    lastEntryID = entries.last?.entryId
    lastRecordedAt = entries.last?.recordedAt
    lastSummary = entries.last?.summary
  }
}

struct ToolCallTimelinePresentationOutput: Equatable, Sendable {
  let presentation: ToolCallTimelinePresentation
  let layout: ToolCallTimelineVirtualizedLayout
  let announcementSnapshot: ToolCallTimelineAnnouncementSnapshot
  let overflowAnnouncement: ToolCallTimelineOverflowAnnouncement?
}

@MainActor
final class ToolCallTimelineScrollMetricsDeferrer {
  private var generation: UInt64 = 0

  func schedule(
    _ scrollMetrics: ToolCallTimelineScrollMetrics,
    apply: @escaping @MainActor (ToolCallTimelineScrollMetrics) -> Void
  ) {
    generation &+= 1
    let scheduledGeneration = generation
    Task { @MainActor in
      await Task.yield()
      guard self.generation == scheduledGeneration else {
        return
      }
      apply(scrollMetrics)
    }
  }
}

actor ToolCallTimelinePresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private var cachedInput: ToolCallTimelinePresentationInput?
  private var cachedOutput = ToolCallTimelinePresentationOutput(
    presentation: .empty,
    layout: .empty,
    announcementSnapshot: .empty,
    overflowAnnouncement: nil
  )

  func compute(input: ToolCallTimelinePresentationInput) -> ToolCallTimelinePresentationOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "tool_call_timeline.presentation.compute",
      id: signpostID,
      "entries=\(input.entries.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "tool_call_timeline.presentation.compute",
        interval,
        "rows=\(self.cachedOutput.presentation.rows.count, privacy: .public)"
      )
    }
    let presentation = ToolCallTimelineView.materialisePresentation(from: input.entries)
    let layout = ToolCallTimelineVirtualizedLayout(
      presentation: presentation,
      scrollMetrics: input.scrollMetrics
    )
    let announcementSnapshot = ToolCallTimelineAnnouncementSnapshot(
      rows: presentation.rows,
      liveRowIDs: input.liveAnnouncementRowIDs
    )
    let overflowAnnouncement: ToolCallTimelineOverflowAnnouncement? =
      if let overflowNotice = input.overflowNotice {
        ToolCallTimelineOverflowAnnouncement(
          id: overflowNotice.recordedAt,
          text: ToolCallTimelineView.overflowNoticeText(
            rawUpdateCount: overflowNotice.rawUpdateCount,
            visibleToolCallCount: overflowNotice.displayedEventCount
          )
        )
      } else {
        nil
      }
    cachedInput = input
    cachedOutput = ToolCallTimelinePresentationOutput(
      presentation: presentation,
      layout: layout,
      announcementSnapshot: announcementSnapshot,
      overflowAnnouncement: overflowAnnouncement
    )
    return cachedOutput
  }

  func waitForIdle() async {}
}
