import SwiftUI
import WidgetKit

struct MobileNeedsYouWidget: Widget {
  static let kind = "mobile-needs-you"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      VStack(alignment: .leading, spacing: 8) {
        Label("Needs You", systemImage: "dot.radiowaves.left.and.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.red)
        Text("\(entry.snapshot.needsYouCount)")
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .monospacedDigit()
        Text(entry.snapshot.sortedAttention.first?.title ?? "All clear")
          .font(.caption)
          .lineLimit(2)
      }
      .containerBackground(.fill.tertiary, for: .widget)
      .widgetURL(URL(string: "harness://today"))
    }
    .configurationDisplayName("Needs You")
    .description("Critical Harness Monitor items waiting for you.")
    .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular])
  }
}
