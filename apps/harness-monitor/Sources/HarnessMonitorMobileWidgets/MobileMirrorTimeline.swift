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
    completion(MobileMirrorEntry(date: .now, snapshot: MobileDemoFixtures.snapshot()))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<MobileMirrorEntry>) -> Void
  ) {
    let entry = MobileMirrorEntry(date: .now, snapshot: MobileDemoFixtures.snapshot())
    completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
  }
}
