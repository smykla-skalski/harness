import HarnessMonitorKit
import SwiftUI

struct SidebarSessionList: View {
  @Bindable var store: MonitorStore

  var body: some View {
    Group {
      if store.groupedSessions.isEmpty {
        emptyState
      } else {
        populatedList
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No sessions indexed yet")
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Text("Start the daemon or refresh after launching a harness session.")
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .monitorCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sidebarEmptyState)
  }

  private var populatedList: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(store.groupedSessions) { group in
          VStack(alignment: .leading, spacing: 10) {
            projectHeader(group)
            ForEach(group.sessions) { session in
              sessionRow(session)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityFrameMarker(MonitorAccessibility.sidebarSessionListContent)
    }
    .accessibilityIdentifier(MonitorAccessibility.sidebarSessionList)
  }

  private func projectHeader(_ group: MonitorStore.SessionGroup) -> some View {
    HStack {
      Text(group.project.name)
        .font(.system(.headline, design: .serif, weight: .semibold))
        .foregroundStyle(MonitorTheme.sidebarHeader)
      Spacer()
      Text("\(group.sessions.count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(MonitorTheme.sidebarMuted)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(MonitorTheme.surface)
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(MonitorTheme.controlBorder, lineWidth: 1)
        )
    )
    .accessibilityIdentifier(
      MonitorAccessibility.projectHeader(group.project.projectId)
    )
    .accessibilityFrameMarker(
      MonitorAccessibility.projectHeaderFrame(group.project.projectId)
    )
  }

  private func sessionRow(_ session: SessionSummary) -> some View {
    Button {
      store.primeSessionSelection(session.sessionId)
      Task { await store.selectSession(session.sessionId) }
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 10) {
          Text(session.context)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.leading)
            .lineLimit(2)
          Spacer(minLength: 12)
          if store.subscribedSessionIDs.contains(session.sessionId) {
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.caption2)
              .foregroundStyle(MonitorTheme.success)
              .symbolEffect(.variableColor.iterative, isActive: true)
          }
          Circle()
            .fill(statusColor(for: session.status))
            .frame(width: 10, height: 10)
        }
        Text(session.sessionId)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
        HStack(spacing: 12) {
          labelChip("\(session.metrics.activeAgentCount) active")
          labelChip("\(session.metrics.inProgressTaskCount) moving")
          labelChip(formatTimestamp(session.lastActivityAt))
        }
      }
      .foregroundStyle(MonitorTheme.ink)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(
            store.selectedSessionID == session.sessionId
              ? MonitorTheme.surfaceHover : MonitorTheme.surface
          )
          .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(MonitorTheme.controlBorder.opacity(0.7), lineWidth: 1)
          )
      )
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .accessibilityIdentifier(MonitorAccessibility.sessionRow(session.sessionId))
    .buttonStyle(.plain)
  }

  private func labelChip(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(MonitorTheme.surface, in: Capsule())
  }
}
