import SwiftUI
import WidgetKit

struct MobileCommandQueueWidget: Widget {
  static let kind = "mobile-command-queue"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      let active = entry.snapshot.commands.filter { !$0.status.isTerminal }.count
      VStack(alignment: .leading, spacing: 8) {
        Label("Commands", systemImage: "terminal")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        Text("\(active)")
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .monospacedDigit()
        Text(entry.snapshot.commands.first?.title ?? "No queued commands")
          .font(.caption)
          .lineLimit(2)
      }
      .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Command Queue")
    .description("Remote Harness Monitor command status.")
    .supportedFamilies([.systemSmall, .accessoryRectangular])
  }
}
