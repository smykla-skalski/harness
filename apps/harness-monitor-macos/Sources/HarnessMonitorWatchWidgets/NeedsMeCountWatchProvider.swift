import Foundation
import HarnessMonitorCloudKit
import WidgetKit

struct NeedsMeCountTimelineEntry: TimelineEntry {
    let date: Date
    let count: Int
    let updatedAt: Date?
}

struct NeedsMeCountWatchProvider: TimelineProvider {
    typealias Entry = NeedsMeCountTimelineEntry

    func placeholder(in context: Context) -> NeedsMeCountTimelineEntry {
        NeedsMeCountTimelineEntry(date: Date(), count: 0, updatedAt: nil)
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
        let store = NeedsMeCloudKitStore()
        do {
            if let snapshot = try await store.fetchCurrent() {
                return NeedsMeCountTimelineEntry(
                    date: Date(),
                    count: Int(snapshot.count),
                    updatedAt: snapshot.updatedAt
                )
            }
        } catch {
            // Soft fail: render with no updatedAt to signal staleness
        }
        return NeedsMeCountTimelineEntry(date: Date(), count: 0, updatedAt: nil)
    }
}
