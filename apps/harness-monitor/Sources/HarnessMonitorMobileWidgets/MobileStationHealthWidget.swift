import SwiftUI
import WidgetKit

struct MobileStationHealthWidget: Widget {
  static let kind = "mobile-station-health"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      let online = entry.snapshot.stations.filter { $0.state == .online }.count
      VStack(alignment: .leading, spacing: 8) {
        Label("Stations", systemImage: "desktopcomputer")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.blue)
        Text("\(online)/\(entry.snapshot.stations.count)")
          .font(.system(.title, design: .rounded, weight: .bold))
          .monospacedDigit()
        Text(entry.snapshot.stations.first?.displayName ?? "No paired Macs")
          .font(.caption)
          .lineLimit(1)
      }
      .containerBackground(.fill.tertiary, for: .widget)
      .widgetURL(URL(string: "harness://today"))
    }
    .configurationDisplayName("Station Health")
    .description("Paired Mac relay health.")
    .supportedFamilies([.systemSmall, .accessoryRectangular])
  }
}
