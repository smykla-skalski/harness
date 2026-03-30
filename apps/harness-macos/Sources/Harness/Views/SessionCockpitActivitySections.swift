import HarnessKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let signals: [SessionSignalRecord]
  let inspectSignal: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Signals")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HarnessGlassContainer(spacing: 12) {
        ForEach(signals) { signal in
          Button {
            inspectSignal(signal.signal.signalId)
          } label: {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 6) {
                Text(signal.signal.command)
                  .font(.system(.headline, design: .rounded, weight: .semibold))
                Text(signal.signal.payload.message)
                  .font(.subheadline)
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 6) {
                Text(signal.status.title)
                  .font(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
          }
          .harnessInteractiveCardButtonStyle()
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.95).combined(with: .opacity),
              removal: .opacity
            ))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard()
  }
}

struct SessionCockpitTimelineSection: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let timeline: [TimelineEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Timeline")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(timeline) { entry in
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 999)
            .fill(HarnessTheme.accent(for: themeStyle).opacity(0.35))
            .frame(width: 8)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.summary)
              .font(.system(.body, design: .rounded, weight: .semibold))
            Text("\(entry.kind) • \(formatTimestamp(entry.recordedAt))")
              .font(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          Spacer()
          if let taskID = entry.taskId {
            Text(taskID)
              .font(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
          HarnessInsetPanelBackground(
            cornerRadius: 16,
            fillOpacity: 0.05,
            strokeOpacity: 0.10
          )
        }
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
          ))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard()
  }
}
