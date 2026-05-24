import SwiftUI

struct DashboardDiagnosticsSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.headline.weight(.semibold))
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .top) {
      Divider().opacity(0.34)
    }
  }
}

struct DashboardDiagnosticsRecordStrip: View {
  let title: String
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(values, id: \.self) { value in
          Text(value)
            .scaledFont(.caption.weight(.semibold))
            .harnessPillPadding()
            .harnessContentPill()
        }
      }
    }
  }
}

struct DashboardDiagnosticsEvent: Identifiable {
  let id = UUID()
  let source: String
  let level: String
  let recordedAt: String
  let message: String
}

struct DashboardDiagnosticsEventRow: View {
  let event: DashboardDiagnosticsEvent

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Text(event.source)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(event.level)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.caution)
        Text(event.recordedAt)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Text(event.message)
        .scaledFont(.callout)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.24)
    }
  }
}
