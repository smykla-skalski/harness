import HarnessKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let signals: [SessionSignalRecord]
  let inspectSignal: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Signals")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if signals.isEmpty {
        ContentUnavailableView {
          Label("No signals", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
          Text("Signals appear when agents send or receive commands.")
        }
        .frame(maxWidth: .infinity)
      }
      LazyVStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
        ForEach(signals) { signal in
          Button {
            inspectSignal(signal.signal.signalId)
          } label: {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
                Text(signal.signal.command)
                  .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
                Text(signal.signal.payload.message)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: HarnessTheme.itemSpacing) {
                Text(signal.status.title)
                  .scaledFont(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt))
                  .scaledFont(.caption.monospaced())
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HarnessTheme.cardPadding)
          }
          .harnessInteractiveCardButtonStyle()
          .contextMenu {
            Button {
              inspectSignal(signal.signal.signalId)
            } label: {
              Label("Inspect", systemImage: "info.circle")
            }
            Divider()
            Button {
              HarnessClipboard.copy(signal.signal.signalId)
            } label: {
              Label("Copy Signal ID", systemImage: "doc.on.doc")
            }
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Signals") {
  SessionCockpitSignalsSection(signals: PreviewFixtures.signals, inspectSignal: { _ in })
    .padding()
    .frame(width: 960)
}

struct SessionCockpitTimelineSection: View {
  let timeline: [TimelineEntry]

  var body: some View {
    LazyVStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if timeline.isEmpty {
        ContentUnavailableView {
          Label("No activity yet", systemImage: "clock")
        } description: {
          Text("Timeline entries appear as agents work on tasks.")
        }
      }
      ForEach(timeline) { entry in
        HStack(alignment: .top, spacing: HarnessTheme.sectionSpacing) {
          RoundedRectangle(cornerRadius: 999)
            .fill(HarnessTheme.accent.opacity(0.35))
            .frame(width: 8)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.summary)
              .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            Text("\(entry.kind) • \(formatTimestamp(entry.recordedAt))")
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          Spacer()
          if let taskID = entry.taskId {
            Text(taskID)
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
          Button {
            HarnessClipboard.copy(entry.summary)
          } label: {
            Label("Copy Summary", systemImage: "doc.on.doc")
          }
          if let taskID = entry.taskId {
            Button {
              HarnessClipboard.copy(taskID)
            } label: {
              Label("Copy Task ID", systemImage: "doc.on.doc")
            }
          }
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
