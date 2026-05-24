import Foundation
import HarnessMonitorCore
import WidgetKit

struct MobileMirrorEntry: TimelineEntry {
  let date: Date
  let snapshot: MobileMirrorSnapshot
}

struct MobileMirrorTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> MobileMirrorEntry {
    MobileMirrorEntry(date: .now, snapshot: MobileDemoFixtures.snapshot())
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (MobileMirrorEntry) -> Void
  ) {
    completion(MobileMirrorEntry(date: .now, snapshot: Self.snapshot(for: context)))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<MobileMirrorEntry>) -> Void
  ) {
    let now = Date()
    let entry = MobileMirrorEntry(date: now, snapshot: Self.snapshot(for: context, now: now))
    completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60))))
  }

  private static func snapshot(
    for context: Context,
    now: Date = .now
  ) -> MobileMirrorSnapshot {
    if context.isPreview {
      return MobileDemoFixtures.snapshot(now: now)
    }
    guard let store = MobileSharedSnapshotStore(),
      let snapshot = try? store.loadLatestSnapshot()
    else {
      return .empty(now: now)
    }
    return snapshot
  }
}
