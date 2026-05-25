import SwiftUI
import WidgetKit

struct MobileCommandQueueWidget: Widget {
  static let kind = "mobile-command-queue"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      let active = entry.snapshot.commands.filter { !$0.status.isTerminal }.count
      let command = entry.activeCommandPresentation
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Label("Commands", systemImage: "terminal")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Spacer()
          Text(entry.state.shortTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        Text("\(active)")
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .monospacedDigit()
        Text(command?.commandTitle ?? "No queued commands")
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(command.map { "\($0.status) - \($0.stationName)" } ?? "Signed receipts appear here")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .containerBackground(.fill.tertiary, for: .widget)
      .widgetURL(URL(string: "harness://commands"))
    }
    .configurationDisplayName("Command Queue")
    .description("Remote Harness Monitor command status.")
    .supportedFamilies([.systemSmall, .accessoryRectangular])
  }
}
