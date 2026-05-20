import HarnessMonitorKit
import SwiftUI

struct DashboardSidebarRecentSessionsSection: View {
  let store: HarnessMonitorStore
  let sessions: [SessionSummary]

  private var recentSessions: ArraySlice<SessionSummary> {
    sessions.prefix(8)
  }

  var body: some View {
    Section("Sessions") {
      if recentSessions.isEmpty {
        Text("No recent sessions")
          .foregroundStyle(.secondary)
      } else {
        ForEach(recentSessions) { session in
          DashboardSidebarRecentSessionRow(store: store, session: session)
        }
      }
    }
  }
}

private struct DashboardSidebarRecentSessionRow: View {
  let store: HarnessMonitorStore
  let session: SessionSummary
  @Environment(\.openWindow)
  private var openWindow

  private var presentation: HarnessMonitorStore.SessionSummaryPresentation {
    store.sessionSummaryPresentation(for: session)
  }

  private var subtitle: String? {
    let metadata = session.projectAndWorktreeDisplayLabel(separator: "·")
    return metadata.isEmpty ? nil : metadata
  }

  private var accessibilityLabel: String {
    if let subtitle {
      return "\(session.displayTitle), \(subtitle)"
    }
    return session.displayTitle
  }

  var body: some View {
    SessionSidebarRow(
      title: session.displayTitle,
      subtitle: subtitle,
      systemImage: "rectangle.stack",
      severityShape: .dot,
      severityTint: statusColor(for: presentation.statusTone)
    )
    .tag(DashboardSidebarSelection.session(session.sessionId))
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionRow(session.sessionId))
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(presentation.accessibilityStatusText)
    .accessibilityHint("Open session window")
    .accessibilityAction {
      openSessionWindow()
    }
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
