import Foundation
import HarnessMonitorCloudKit
import HarnessMonitorCore
import WidgetKit

struct NeedsMeCountTimelineEntry: TimelineEntry {
  let date: Date
  let count: Int
  let updatedAt: Date?
  let state: NeedsMeCountState

  init(
    date: Date,
    count: Int,
    updatedAt: Date?,
    state: NeedsMeCountState = .live
  ) {
    self.date = date
    self.count = count
    self.updatedAt = updatedAt
    self.state = state
  }

  init(date: Date, resolution: NeedsMeCountResolution) {
    self.date = date
    self.count = resolution.count
    self.updatedAt = resolution.updatedAt
    self.state = resolution.state
  }
}

struct NeedsMeCountWatchProvider: TimelineProvider {
  typealias Entry = NeedsMeCountTimelineEntry

  func placeholder(in context: Context) -> NeedsMeCountTimelineEntry {
    NeedsMeCountTimelineEntry(date: Date(), count: 0, updatedAt: nil, state: .live)
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (NeedsMeCountTimelineEntry) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    Task {
      let entry = await Self.fetchEntry()
      safeCompletion(entry)
    }
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<NeedsMeCountTimelineEntry>) -> Void
  ) {
    nonisolated(unsafe) let safeCompletion = completion
    Task {
      let entry = await Self.fetchEntry()
      let nextUpdate = Date().addingTimeInterval(15 * 60)
      let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
      safeCompletion(timeline)
    }
  }

  private static func fetchEntry() async -> NeedsMeCountTimelineEntry {
    let now = Date()
    if let mirroredEntry = mirroredReviewEntry(now: now) {
      return mirroredEntry
    }
    let store = NeedsMeCloudKitStore.shared
    do {
      let primary = try await store.fetchCurrent()
      if primary != nil {
        let resolution = NeedsMeCountResolver.resolve(primary: primary, fallback: nil, error: nil)
        return NeedsMeCountTimelineEntry(date: now, resolution: resolution)
      }
      let fallback = await store.lastKnown()
      let resolution = NeedsMeCountResolver.resolve(primary: nil, fallback: fallback, error: nil)
      return NeedsMeCountTimelineEntry(date: now, resolution: resolution)
    } catch let typed as NeedsMeCloudKitError {
      let fallback = await store.lastKnown()
      let resolution = NeedsMeCountResolver.resolve(primary: nil, fallback: fallback, error: typed)
      return NeedsMeCountTimelineEntry(date: now, resolution: resolution)
    } catch {
      let fallback = await store.lastKnown()
      let resolution = NeedsMeCountResolver.resolve(
        primary: nil,
        fallback: fallback,
        error: .underlying(String(describing: error))
      )
      return NeedsMeCountTimelineEntry(date: now, resolution: resolution)
    }
  }

  private static func mirroredReviewEntry(now: Date) -> NeedsMeCountTimelineEntry? {
    guard
      let store = MobileSharedSnapshotStore(),
      let snapshot = try? store.loadLatestSnapshot(),
      snapshot.hasMirroredContent
    else {
      return nil
    }
    let state: NeedsMeCountState = snapshot.expiresAt > now ? .live : .cached
    return NeedsMeCountTimelineEntry(
      date: now,
      count: snapshot.reviews.filter(\.needsYou).count,
      updatedAt: snapshot.generatedAt,
      state: state
    )
  }
}

extension MobileMirrorSnapshot {
  fileprivate var hasMirroredContent: Bool {
    !stations.isEmpty || !reviews.isEmpty || !attention.isEmpty
      || !sessions.isEmpty || !taskBoardItems.isEmpty || !commands.isEmpty
  }
}
