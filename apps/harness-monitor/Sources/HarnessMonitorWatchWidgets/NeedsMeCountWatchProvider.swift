import Foundation
import HarnessMonitorCloudKit
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
}

enum NeedsMeCountState: Equatable {
  case live
  case cached
  case notAuthenticated
  case offline
  case unknownError
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
    let store = NeedsMeCloudKitStore.shared
    do {
      if let snapshot = try await store.fetchCurrent() {
        return NeedsMeCountTimelineEntry(
          date: Date(),
          count: Int(snapshot.count),
          updatedAt: snapshot.updatedAt,
          state: .live
        )
      }
      if let cached = await store.lastKnown() {
        return NeedsMeCountTimelineEntry(
          date: Date(),
          count: Int(cached.count),
          updatedAt: cached.updatedAt,
          state: .cached
        )
      }
      return NeedsMeCountTimelineEntry(date: Date(), count: 0, updatedAt: nil, state: .live)
    } catch NeedsMeCloudKitError.notAuthenticated {
      return await entry(forState: .notAuthenticated)
    } catch NeedsMeCloudKitError.networkUnavailable {
      let fallback = await store.lastKnown()
      return entry(snapshot: fallback, defaultState: .offline, cachedState: .cached)
    } catch {
      return await entry(forState: .unknownError)
    }
  }

  private static func entry(forState state: NeedsMeCountState) async -> NeedsMeCountTimelineEntry {
    let cached = await NeedsMeCloudKitStore.shared.lastKnown()
    return entry(snapshot: cached, defaultState: state, cachedState: state)
  }

  private static func entry(
    snapshot: NeedsMeSnapshot?,
    defaultState: NeedsMeCountState,
    cachedState: NeedsMeCountState
  ) -> NeedsMeCountTimelineEntry {
    if let snapshot {
      return NeedsMeCountTimelineEntry(
        date: Date(),
        count: Int(snapshot.count),
        updatedAt: snapshot.updatedAt,
        state: cachedState
      )
    }
    return NeedsMeCountTimelineEntry(
      date: Date(),
      count: 0,
      updatedAt: nil,
      state: defaultState
    )
  }
}
