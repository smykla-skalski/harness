import SwiftUI
import WidgetKit

struct MobileNeedsYouWidget: Widget {
  static let kind = "mobile-needs-you"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: MobileMirrorTimelineProvider()) { entry in
      MobileNeedsYouWidgetView(entry: entry)
    }
    .configurationDisplayName("Needs you")
    .description("Critical Harness Monitor items waiting for you")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
  }
}

private struct MobileNeedsYouWidgetView: View {
  @Environment(\.widgetFamily)
  private var family
  let entry: MobileMirrorEntry

  var body: some View {
    Group {
      switch family {
      case .accessoryCircular:
        Gauge(value: Double(min(entry.snapshot.needsYouCount, 99)), in: 0...99) {
          Image(systemName: "dot.radiowaves.left.and.right")
        } currentValueLabel: {
          Text("\(entry.snapshot.needsYouCount)")
            .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel("Needs you")
        .accessibilityValue("\(entry.snapshot.needsYouCount)")
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 2) {
          Text("Needs you \(entry.snapshot.needsYouCount)")
            .font(.headline)
            .monospacedDigit()
          Text(entry.primaryAttention?.title ?? entry.state.shortTitle)
            .font(.caption)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
      default:
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("Needs you", systemImage: "dot.radiowaves.left.and.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.red)
            Spacer()
            Text(entry.state.shortTitle)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          Text("\(entry.snapshot.needsYouCount)")
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .monospacedDigit()
          Text(entry.primaryAttention?.title ?? "All clear")
            .font(.caption)
            .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .containerBackground(.fill.tertiary, for: .widget)
    .widgetURL(URL(string: "harness://today"))
  }
}
