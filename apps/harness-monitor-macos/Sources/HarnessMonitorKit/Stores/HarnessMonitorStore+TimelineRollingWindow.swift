import Foundation

extension HarnessMonitorStore {
  func resolvedSelectedTimelineWindow(
    _ response: TimelineWindowResponse,
    request: TimelineWindowRequest,
    retainedLimit: Int?
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse) {
    if retainedLimit != nil {
      if let rollingResolution = TimelineRollingWindowResolver.resolve(
        existingTimeline: timeline,
        currentWindow: timelineWindow,
        response: response,
        request: request,
        retainedLimit: retainedLimit
      ) {
        return (rollingResolution.timeline, rollingResolution.timelineWindow)
      }
    }

    let resolvedTimeline = response.entries ?? timeline
    let resolvedWindow =
      normalizedTimelineWindow(response.metadataOnly, loadedTimeline: resolvedTimeline)
      ?? response.metadataOnly
    return (resolvedTimeline, resolvedWindow)
  }

  func resolvedSelectedTimelinePage(
    _ response: TimelineWindowResponse,
    currentRevision: Int64?,
    retainedLimit: Int?
  ) -> (timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?) {
    if response.windowStart == 0 || response.revision != currentRevision {
      let resolvedTimeline = response.entries ?? timeline
      return (
        resolvedTimeline,
        normalizedTimelineWindow(response.metadataOnly, loadedTimeline: resolvedTimeline)
      )
    }

    if let responseEntries = response.entries {
      let resolution = TimelineRollingWindowResolver.appendingOlder(
        existingTimeline: timeline,
        currentWindow: timelineWindow,
        response: response,
        olderEntries: responseEntries,
        retainedLimit: retainedLimit
      )
      return (resolution.timeline, resolution.timelineWindow)
    }

    return (
      timeline,
      normalizedTimelineWindow(response.metadataOnly, loadedTimeline: timeline)
    )
  }
}

struct TimelineRollingWindowResolution {
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse
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
