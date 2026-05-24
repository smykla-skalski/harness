import Foundation
import HarnessMonitorIntents
import WidgetKit

struct NeedsMeCountEntry: TimelineEntry {
  let date: Date
  let count: Int
}

struct NeedsMeCountProvider: TimelineProvider {
  private static let refreshInterval: TimeInterval = 30 * 60

  func placeholder(in context: Context) -> NeedsMeCountEntry {
    NeedsMeCountEntry(date: .now, count: 0)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (NeedsMeCountEntry) -> Void
  ) {
    if context.isPreview {
      completion(NeedsMeCountEntry(date: .now, count: 3))
      return
    }
    completion(NeedsMeCountEntry(date: .now, count: 0))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<NeedsMeCountEntry>) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    Task {
      let count = (try? await GetNeedsMeCountIntent().resolveCount()) ?? 0
      let entry = NeedsMeCountEntry(date: .now, count: count)
      let next = Date.now.addingTimeInterval(Self.refreshInterval)
      safeCompletion(Timeline(entries: [entry], policy: .after(next)))
    }
  }
}
