import HarnessMonitorKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let signals: [SessionSignalRecord]
  let isExtensionsLoading: Bool
  let inspectSignal: (String) -> Void
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Signals")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if signals.isEmpty && isExtensionsLoading {
        HarnessMonitorLoadingStateView(title: "Loading signals")
          .frame(maxWidth: .infinity)
          .transition(.opacity)
      } else if signals.isEmpty {
        ContentUnavailableView {
          Label("No signals", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
          Text("Signals appear when agents send or receive commands.")
        }
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
      }
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        ForEach(signals) { signal in
          Button {
            inspectSignal(signal.signal.signalId)
          } label: {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
                Text(signal.signal.command)
                  .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
                Text(signal.signal.payload.message)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: HarnessMonitorTheme.itemSpacing) {
                Text(signal.status.title)
                  .scaledFont(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt, configuration: dateTimeConfiguration))
                  .scaledFont(.caption.monospaced())
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HarnessMonitorTheme.cardPadding)
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
              HarnessMonitorClipboard.copy(signal.signal.signalId)
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
  SessionCockpitSignalsSection(signals: PreviewFixtures.signals, isExtensionsLoading: false, inspectSignal: { _ in })
    .padding()
    .frame(width: 960)
}

struct SessionCockpitTimelineSection: View {
  let timeline: [TimelineEntry]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if timeline.isEmpty {
        ContentUnavailableView {
          Label("No activity yet", systemImage: "clock")
        } description: {
          Text("Timeline entries appear as agents work on tasks.")
        }
        .frame(maxWidth: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
            ForEach(timeline) { entry in
              HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
                RoundedRectangle(cornerRadius: 999)
                  .fill(HarnessMonitorTheme.accent.opacity(0.35))
                  .frame(width: 8)
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                  Text(entry.summary)
                    .scaledFont(.system(.body, design: .rounded, weight: .semibold))
                  Text(
                    "\(entry.kind) • "
                      + "\(formatTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))"
                  )
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
                Spacer()
                if let taskID = entry.taskId {
                  Text(taskID)
                    .scaledFont(.caption.monospaced())
                    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contextMenu {
                Button {
                  HarnessMonitorClipboard.copy(entry.summary)
                } label: {
                  Label("Copy Summary", systemImage: "doc.on.doc")
                }
                if let taskID = entry.taskId {
                  Button {
                    HarnessMonitorClipboard.copy(taskID)
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
        }
        .scrollIndicators(.automatic)
        .frame(
          maxHeight: SessionCockpitLayout.timelineSectionMaxHeight,
          alignment: .top
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
