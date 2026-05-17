import Foundation

struct TimelineRollingWindowResolution: Sendable {
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse
}

struct TimelineWindowResolutionOutput: Sendable {
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
}

enum TimelineRollingWindowResolver {
  static func resolve(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int?
  ) -> TimelineRollingWindowResolution? {
    guard let currentWindow,
      currentWindow.revision == response.revision,
      let responseEntries = response.entries
    else {
      return nil
    }
    if request.before != nil {
      return appendingOlder(
        existingTimeline: existingTimeline,
        currentWindow: currentWindow,
        response: response,
        olderEntries: responseEntries,
        retainedLimit: retainedLimit
      )
    }
    if request.after != nil {
      return prependingNewer(
        existingTimeline: existingTimeline,
        currentWindow: currentWindow,
        response: response,
        newerEntries: responseEntries,
        retainedLimit: retainedLimit
      )
    }
    return nil
  }

  static func appendingOlder(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    olderEntries: [TimelineEntry],
    retainedLimit: Int?
  ) -> TimelineRollingWindowResolution {
    let mergedTimeline = mergeAppending(olderEntries, into: existingTimeline)
    let retainedTimeline = evictNewestIfNeeded(mergedTimeline, retainedLimit: retainedLimit)
    let evictedCount = mergedTimeline.count - retainedTimeline.count
    let currentStart = currentWindow?.windowStart ?? 0
    let windowStart = currentStart + evictedCount
    let windowEnd = windowStart + retainedTimeline.count
    let totalCount = max(response.totalCount, max(currentWindow?.totalCount ?? 0, windowEnd))
    let hasNewer = (currentWindow?.hasNewer ?? (currentStart > 0)) || windowStart > 0
    let resolvedWindow = TimelineWindowResponse(
      revision: response.revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: response.hasOlder || windowEnd < totalCount,
      hasNewer: hasNewer,
      oldestCursor: retainedTimeline.last.map(makeCursor(entry:)),
      newestCursor: retainedTimeline.first.map(makeCursor(entry:)),
      entries: nil,
      unchanged: response.unchanged
    )
    return TimelineRollingWindowResolution(
      timeline: retainedTimeline,
      timelineWindow: resolvedWindow
    )
  }

  static func prependingNewer(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    newerEntries: [TimelineEntry],
    retainedLimit: Int?
  ) -> TimelineRollingWindowResolution {
    let mergedTimeline = mergePrepending(newerEntries, into: existingTimeline)
    let retainedTimeline = evictOldestIfNeeded(mergedTimeline, retainedLimit: retainedLimit)
    let windowStart = max(0, response.windowStart)
    let windowEnd = windowStart + retainedTimeline.count
    let totalCount = max(response.totalCount, max(currentWindow?.totalCount ?? 0, windowEnd))
    let hasOlder = (currentWindow?.hasOlder ?? (windowEnd < totalCount)) || windowEnd < totalCount
    let resolvedWindow = TimelineWindowResponse(
      revision: response.revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowEnd,
      hasOlder: hasOlder,
      hasNewer: response.hasNewer || windowStart > 0,
      oldestCursor: retainedTimeline.last.map(makeCursor(entry:)),
      newestCursor: retainedTimeline.first.map(makeCursor(entry:)),
      entries: nil,
      unchanged: response.unchanged
    )
    return TimelineRollingWindowResolution(
      timeline: retainedTimeline,
      timelineWindow: resolvedWindow
    )
  }

  private static func mergeAppending(
    _ olderEntries: [TimelineEntry],
    into existingTimeline: [TimelineEntry]
  ) -> [TimelineEntry] {
    guard !olderEntries.isEmpty else { return existingTimeline }
    var merged = existingTimeline
    var keys = Set(existingTimeline.map(TimelineEntryKey.init(entry:)))
    for entry in olderEntries where keys.insert(TimelineEntryKey(entry: entry)).inserted {
      merged.append(entry)
    }
    return merged
  }

  private static func mergePrepending(
    _ newerEntries: [TimelineEntry],
    into existingTimeline: [TimelineEntry]
  ) -> [TimelineEntry] {
    guard !newerEntries.isEmpty else { return existingTimeline }
    var merged = newerEntries
    var keys = Set(newerEntries.map(TimelineEntryKey.init(entry:)))
    for entry in existingTimeline where keys.insert(TimelineEntryKey(entry: entry)).inserted {
      merged.append(entry)
    }
    return merged
  }

  private static func evictNewestIfNeeded(
    _ entries: [TimelineEntry],
    retainedLimit: Int?
  ) -> [TimelineEntry] {
    guard let retainedLimit else { return entries }
    let overflow = entries.count - max(1, retainedLimit)
    guard overflow > 0 else { return entries }
    return Array(entries.dropFirst(overflow))
  }

  private static func evictOldestIfNeeded(
    _ entries: [TimelineEntry],
    retainedLimit: Int?
  ) -> [TimelineEntry] {
    guard let retainedLimit else { return entries }
    let overflow = entries.count - max(1, retainedLimit)
    guard overflow > 0 else { return entries }
    return Array(entries.dropLast(overflow))
  }

  private static func makeCursor(entry: TimelineEntry) -> TimelineCursor {
    TimelineCursor(recordedAt: entry.recordedAt, entryId: entry.entryId)
  }
}

private struct TimelineEntryKey: Hashable {
  let recordedAt: String
  let entryID: String

  init(entry: TimelineEntry) {
    recordedAt = entry.recordedAt
    entryID = entry.entryId
  }
}

actor TimelineWindowWorker {
  func resolveSelectedWindow(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int?
  ) -> TimelineWindowResolutionOutput {
    if retainedLimit != nil {
      if let rollingResolution = TimelineRollingWindowResolver.resolve(
        existingTimeline: existingTimeline,
        currentWindow: currentWindow,
        response: response,
        request: request,
        retainedLimit: retainedLimit
      ) {
        return TimelineWindowResolutionOutput(
          timeline: rollingResolution.timeline,
          timelineWindow: rollingResolution.timelineWindow
        )
      }
    }

    let resolvedTimeline = response.entries ?? existingTimeline
    let resolvedWindow =
      HarnessMonitorStore.normalizedTimelineWindow(
        response.metadataOnly,
        loadedTimeline: resolvedTimeline
      )
      ?? response.metadataOnly
    return TimelineWindowResolutionOutput(
      timeline: resolvedTimeline,
      timelineWindow: resolvedWindow
    )
  }

  func resolveSelectedPage(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    currentRevision: Int64?,
    retainedLimit: Int?
  ) -> TimelineWindowResolutionOutput {
    if response.windowStart == 0 || response.revision != currentRevision {
      let resolvedTimeline = response.entries ?? existingTimeline
      return TimelineWindowResolutionOutput(
        timeline: resolvedTimeline,
        timelineWindow: HarnessMonitorStore.normalizedTimelineWindow(
          response.metadataOnly,
          loadedTimeline: resolvedTimeline
        )
      )
    }

    if let responseEntries = response.entries {
      let resolution = TimelineRollingWindowResolver.appendingOlder(
        existingTimeline: existingTimeline,
        currentWindow: currentWindow,
        response: response,
        olderEntries: responseEntries,
        retainedLimit: retainedLimit
      )
      return TimelineWindowResolutionOutput(
        timeline: resolution.timeline,
        timelineWindow: resolution.timelineWindow
      )
    }

    return TimelineWindowResolutionOutput(
      timeline: existingTimeline,
      timelineWindow: HarnessMonitorStore.normalizedTimelineWindow(
        response.metadataOnly,
        loadedTimeline: existingTimeline
      )
    )
  }

  func resolveSessionWindow(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse?,
    response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int?
  ) -> TimelineWindowResolutionOutput {
    if let rollingResolution = TimelineRollingWindowResolver.resolve(
      existingTimeline: existingTimeline,
      currentWindow: currentWindow,
      response: response,
      request: request,
      retainedLimit: retainedLimit
    ) {
      return TimelineWindowResolutionOutput(
        timeline: rollingResolution.timeline,
        timelineWindow: rollingResolution.timelineWindow
      )
    }

    let resolvedTimeline = response.entries ?? existingTimeline
    let resolvedWindow =
      HarnessMonitorStore.normalizedTimelineWindow(
        response.metadataOnly,
        loadedTimeline: resolvedTimeline
      )
      ?? response.metadataOnly
    return TimelineWindowResolutionOutput(
      timeline: resolvedTimeline,
      timelineWindow: resolvedWindow
    )
  }

  func prependNewer(
    existingTimeline: [TimelineEntry],
    currentWindow: TimelineWindowResponse,
    response: TimelineWindowResponse,
    newerEntries: [TimelineEntry],
    retainedLimit: Int?
  ) -> TimelineWindowResolutionOutput {
    let resolution = TimelineRollingWindowResolver.prependingNewer(
      existingTimeline: existingTimeline,
      currentWindow: currentWindow,
      response: response,
      newerEntries: newerEntries,
      retainedLimit: retainedLimit
    )
    return TimelineWindowResolutionOutput(
      timeline: resolution.timeline,
      timelineWindow: resolution.timelineWindow
    )
  }

  func normalize(
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?
  ) -> TimelineWindowResolutionOutput {
    TimelineWindowResolutionOutput(
      timeline: timeline,
      timelineWindow: HarnessMonitorStore.normalizedTimelineWindow(
        timelineWindow,
        loadedTimeline: timeline
      )
    )
  }

  func waitForIdle() {}
}
