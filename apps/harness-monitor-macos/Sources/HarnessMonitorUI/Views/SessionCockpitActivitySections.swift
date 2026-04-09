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
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        Text("Signals")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
          .opacity(signals.isEmpty && !isExtensionsLoading ? 0.55 : 1)
        Spacer(minLength: 0)
        if signals.isEmpty && !isExtensionsLoading {
          Text("No signals yet")
            .scaledFont(.system(.body, design: .rounded))
            .foregroundStyle(.tertiary)
            .opacity(0.75)
        }
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
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.sessionSignalCard(signal.signal.signalId)
          )
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
  SessionCockpitSignalsSection(
    signals: PreviewFixtures.signals,
    isExtensionsLoading: false,
    inspectSignal: { _ in }
  )
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
          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(timeline) { entry in
              HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
                RoundedRectangle(cornerRadius: 999)
                  .fill(HarnessMonitorTheme.accent.opacity(0.35))
                  .frame(width: 8, height: 8)
                  .accessibilityHidden(true)
                Text(entry.summary)
                  .scaledFont(.system(.body, design: .rounded, weight: .semibold))
                  .lineLimit(1)
                Spacer()
                Text(
                  "\(entry.kind) • "
                    + "\(formatTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))"
                )
                  .scaledFont(.caption.monospaced())
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(HarnessMonitorTheme.cardPadding)
              .background {
                RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
                  .fill(.primary.opacity(0.04))
              }
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
