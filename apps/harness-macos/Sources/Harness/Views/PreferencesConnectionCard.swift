import HarnessKit
import SwiftUI

struct PreferencesConnectionMetrics: View {
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  private var latencyText: String {
    metrics.latencyMs.map { "\($0)ms" } ?? "--"
  }
  private var uptimeText: String {
    guard let since = metrics.connectedSince else { return "--" }
    let seconds = Int(Date.now.timeIntervalSince(since))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
  }
  private var rateText: String {
    metrics.messagesPerSecond.formatted(
      .number.precision(.fractionLength(1))
    )
  }
  private var reconnectTint: Color {
    metrics.reconnectCount > 0 ? .orange : .green
  }

  var body: some View {
    Section("Metrics") {
      LabeledContent(
        "Transport", value: metrics.transportKind.title
      )
      LabeledContent("Latency", value: latencyText)
      LabeledContent(
        "Messages In", value: "\(metrics.messagesReceived)"
      )
      LabeledContent(
        "Messages Out", value: "\(metrics.messagesSent)"
      )
      LabeledContent("Uptime", value: uptimeText)
      LabeledContent("Reconnects") {
        Text("\(metrics.reconnectCount)")
          .foregroundStyle(reconnectTint)
      }
      LabeledContent("Msg/sec", value: rateText)
      LabeledContent("Quality", value: metrics.quality.title)
    }
    .accessibilityIdentifier(HarnessAccessibility.connectionCard)

    if !events.isEmpty {
      Section("Recent Events") {
        ForEach(events.suffix(10)) { event in
          HStack(spacing: 8) {
            Image(systemName: eventIcon(for: event.kind))
              .foregroundStyle(eventColor(for: event.kind))
              .font(.caption)
              .frame(width: 16)
            Text(event.detail)
              .lineLimit(1)
            Spacer()
            Text(formatTimestamp(event.timestamp))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func eventIcon(
    for kind: ConnectionEventKind
  ) -> String {
    switch kind {
    case .connected: "checkmark.circle.fill"
    case .disconnected: "xmark.circle.fill"
    case .reconnecting: "arrow.clockwise"
    case .fallback: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.octagon.fill"
    }
  }

  private func eventColor(
    for kind: ConnectionEventKind
  ) -> Color {
    switch kind {
    case .connected: .green
    case .disconnected: .red
    case .reconnecting: .orange
    case .fallback: .orange
    case .error: .red
    }
  }
}
