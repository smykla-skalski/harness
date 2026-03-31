import HarnessKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let signals: [SessionSignalRecord]
  let store: HarnessStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Signals")
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      VStack(alignment: .leading, spacing: 12) {
        ForEach(signals) { signal in
          Button {
            store.inspect(signalID: signal.signal.signalId)
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
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionCockpitTimelineSection: View {
  let timeline: [TimelineEntry]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 12) {
      Text("Timeline")
        .font(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      ForEach(timeline) { entry in
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 999)
            .fill(HarnessTheme.accent.opacity(0.35))
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
        .padding(.leading, 18)
        .overlay(alignment: .leading) {
          RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(HarnessTheme.accent.opacity(0.28))
            .frame(width: 3)
        }
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
          ))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
