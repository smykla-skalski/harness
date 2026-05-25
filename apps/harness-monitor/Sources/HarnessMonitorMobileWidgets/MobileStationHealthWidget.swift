import SwiftUI
import WidgetKit

struct MobileStationHealthWidget: Widget {
  static let kind = "mobile-station-health"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      let summary = entry.stationHealthSummary
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Stations", systemImage: "desktopcomputer")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
          Spacer()
          Text(entry.state.shortTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text(summary.countText)
          .font(.system(.title, design: .rounded, weight: .bold))
          .monospacedDigit()
        Text(summary.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(summary.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .containerBackground(.fill.tertiary, for: .widget)
      .widgetURL(URL(string: "harness://today"))
    }
    .configurationDisplayName("Station Health")
    .description("Paired Mac relay health.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
  }
}
