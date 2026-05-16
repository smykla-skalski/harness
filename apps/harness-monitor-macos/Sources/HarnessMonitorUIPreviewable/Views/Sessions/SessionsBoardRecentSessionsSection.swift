import HarnessMonitorKit
import SwiftUI

struct SessionsBoardRecentSessionsSection: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Recent Sessions")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if sessions.isEmpty {
        Text(
          "No sessions indexed yet. Start a harness session and refresh to see it here."
        )
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          ForEach(sessions.prefix(8)) { session in
            DashboardSessionCard(
              store: store,
              session: session
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.recentSessionsCard,
      label: "Recent Sessions",
      value: sessions.isEmpty ? "empty" : "\(sessions.count)"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.recentSessionsCard).frame")
  }
}

private struct DashboardSessionCard: View {
  let store: HarnessMonitorStore
  let session: SessionSummary
  @State private var isHovered = false
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.fontScale)
  private var fontScale

  private var presentation: HarnessMonitorStore.SessionSummaryPresentation {
    store.sessionSummaryPresentation(for: session)
  }

  // Precomputed fonts reading `fontScale` directly. Replaces `.scaledFont(...)`
  // modifier instances - each of those was its own `ScaledFontModifier` view
  // wrapper subscribing to the `fontScale` environment, and 8 recent-session
  // cards x 5 fonts = 40 nested `_EnvironmentKeyWritingModifier` cascades on
  // first paint. Reading the env once per card and computing the Font here
  // collapses that to a single env subscription per card.
  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(
      .system(.headline, design: .rounded, weight: .semibold),
      by: fontScale
    )
  }
  private var statusFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption2.weight(.bold), by: fontScale)
  }
  private var metadataFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.monospaced(), by: fontScale)
  }
  private var timestampFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    Button {
      openSessionWindow()
    } label: {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.sectionSpacing) {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
          .fill(statusColor(for: presentation.statusTone))
          .frame(width: 8)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
            Text(session.displayTitle)
              .font(titleFont)
              .italic(session.title.isEmpty)
              .foregroundStyle(
                session.title.isEmpty
                  ? HarnessMonitorTheme.tertiaryInk
                  : HarnessMonitorTheme.ink
              )
              .multilineTextAlignment(.leading)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(presentation.statusText)
              .font(statusFont)
              .foregroundStyle(statusColor(for: presentation.statusTone))
          }
          HStack(spacing: HarnessMonitorTheme.sectionSpacing) {
            Text(sessionMetadata(session))
              .font(metadataFont)
              .truncationMode(.middle)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            Spacer(minLength: 0)
            Text(formatTimestamp(session.lastActivityAt, configuration: dateTimeConfiguration))
              .font(timestampFont)
              .foregroundStyle(
                isHovered
                  ? HarnessMonitorTheme.secondaryInk
                  : HarnessMonitorTheme.ink.opacity(0.35)
              )
              .animation(.easeInOut(duration: 0.15), value: isHovered)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.cardPadding)
      .fixedSize(horizontal: false, vertical: true)
    }
    // `respondsToHover: false` drops the button-style's own hover region;
    // the local `.onHover` below remains to drive the timestamp opacity
    // fade. Net: one hover region per card instead of two.
    .harnessInteractiveCardButtonStyle(respondsToHover: false)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardSessionCard(session.sessionId))
    .accessibilityFrameMarker(
      HarnessMonitorAccessibility.dashboardSessionCardFrame(session.sessionId)
    )
    .onHover { isHovered = $0 }
    .contextMenu {
      Button {
        openSessionWindow()
      } label: {
        Label("Open Session", systemImage: "rectangle.stack")
      }
      Divider()
      Button {
        HarnessMonitorClipboard.copy(session.title)
      } label: {
        Label("Copy Title", systemImage: "doc.on.doc")
      }
      .disabled(session.title.isEmpty)
      Button {
        HarnessMonitorClipboard.copy(session.sessionId)
      } label: {
        Label("Copy Session ID", systemImage: "doc.on.doc")
      }
      Divider()
      Button(role: .destructive) {
        store.requestRemoveSessionConfirmation(sessionID: session.sessionId)
      } label: {
        Label("Remove Session...", systemImage: "trash")
      }
    }
  }

  private func openSessionWindow() {
    openWindow.openHarnessSessionWindow(sessionID: session.sessionId)
  }
}

private func sessionMetadata(_ session: SessionSummary) -> String {
  session.projectAndWorktreeDisplayLabel()
}
