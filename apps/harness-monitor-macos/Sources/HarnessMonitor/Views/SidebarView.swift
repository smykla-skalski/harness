import HarnessMonitorKit
import Observation
import SwiftUI

struct SidebarView: View {
  @Bindable var store: MonitorStore

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      MonitorTheme.sidebarBackground

      VStack(alignment: .leading, spacing: 18) {
        daemonStatusCard
        filterStrip
        sessionList
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(22)
    }
    .animation(.snappy(duration: 0.24), value: store.groupedSessions)
    .animation(.snappy(duration: 0.24), value: store.isRefreshing)
    .scrollIndicators(.hidden)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sidebarRoot)
  }

  private var daemonStatusCard: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Harness Daemon")
            .font(.system(.title3, design: .rounded, weight: .bold))
          Text(connectionLabel)
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        statusPill
      }

      if store.connectionState == .online {
        HStack(spacing: 8) {
          TransportBadge(kind: store.activeTransport)
          LatencyBadge(latencyMs: store.connectionMetrics.latencyMs)
          ActivityPulse(isActive: true)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if store.connectionMetrics.isFallback {
        FallbackBanner(reason: store.connectionMetrics.fallbackReason) {
          Task { await store.reconnect() }
        }
      }
      if store.isRefreshing || store.connectionState == .connecting {
        MonitorLoadingStateView(title: loadingTitle)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      HStack(spacing: 10) {
        daemonProjectsBadge
        daemonSessionsBadge
        daemonLaunchdBadge
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(spacing: 8) {
        sidebarStartDaemonButton
        sidebarInstallLaunchAgentButton
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(contentPadding: 14)
    .accessibilityIdentifier(MonitorAccessibility.daemonCard)
    .accessibilityFrameMarker(MonitorAccessibility.daemonCardFrame)
  }
  private var filterStrip: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Scope")
        .font(.system(.headline, design: .rounded, weight: .semibold))
      HStack(spacing: 8) {
        ForEach(MonitorStore.SessionFilter.allCases) { filter in
          filterButton(filter)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(MonitorAccessibility.sessionFilterGroup)
    }
    .monitorCard(contentPadding: 16)
  }

  private var sessionList: some View {
    Group {
      if store.groupedSessions.isEmpty {
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
      } else {
        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(store.groupedSessions) { group in
              VStack(alignment: .leading, spacing: 10) {
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

                ForEach(group.sessions) { session in
                  Button {
                    select(sessionID: session.sessionId)
                  } label: {
                    VStack(alignment: .leading, spacing: 8) {
                      HStack(alignment: .top, spacing: 10) {
                        Text(session.context)
                          .font(.system(.body, design: .rounded, weight: .semibold))
                          .multilineTextAlignment(.leading)
                          .lineLimit(2)
                        Spacer(minLength: 12)
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
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityFrameMarker(MonitorAccessibility.sidebarSessionListContent)
        }
        .accessibilityIdentifier(MonitorAccessibility.sidebarSessionList)
      }
    }
  }

  private func filterButton(_ filter: MonitorStore.SessionFilter) -> some View {
    let isSelected = store.sessionFilter == filter

    return Button {
      store.sessionFilter = filter
    } label: {
      Text(filter.rawValue.capitalized)
        .font(.system(.subheadline, design: .rounded, weight: .semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .foregroundStyle(isSelected ? Color.white : MonitorTheme.ink)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? MonitorTheme.accent : MonitorTheme.surfaceHover)
            .overlay(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                  isSelected ? MonitorTheme.accent : MonitorTheme.controlBorder,
                  lineWidth: 1
                )
            )
        )
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(MonitorAccessibility.sessionFilterButton(filter.rawValue))
    .accessibilityValue(
      isSelected ? "selected accent-on-light" : "not selected ink-on-panel"
    )
  }

  private func select(sessionID: String) {
    store.primeSessionSelection(sessionID)
    Task {
      await store.selectSession(sessionID)
    }
  }
}

extension SidebarView {
  fileprivate var sidebarStartDaemonButton: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarStartDaemonButtonFrame) {
      MonitorAsyncActionButton(
        title: "Start Daemon",
        tint: MonitorTheme.accent,
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: MonitorAccessibility.sidebarStartDaemonButton,
        fillsWidth: true
      ) {
        await store.startDaemon()
      }
    }
  }

  fileprivate var sidebarInstallLaunchAgentButton: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarInstallLaunchAgentButtonFrame) {
      MonitorAsyncActionButton(
        title: "Install Launch Agent",
        tint: MonitorTheme.ink,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: MonitorAccessibility.sidebarInstallLaunchAgentButton,
        fillsWidth: true
      ) {
        await store.installLaunchAgent()
      }
    }
  }

  fileprivate var connectionLabel: String {
    switch store.connectionState {
    case .idle:
      "Waiting for bootstrap"
    case .connecting:
      "Connecting to local control plane"
    case .online:
      "Streaming live session updates"
    case .offline(let message):
      message
    }
  }

  fileprivate var loadingTitle: String {
    switch store.connectionState {
    case .connecting:
      "Connecting to the control plane"
    default:
      "Refreshing session index"
    }
  }

  fileprivate var statusPill: some View {
    Text(statusTitle)
      .font(.caption.bold())
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(statusBackground, in: Capsule())
      .foregroundStyle(.white)
  }

  fileprivate var statusTitle: String {
    switch store.connectionState {
    case .online:
      "Online"
    case .connecting:
      "Connecting"
    case .idle:
      "Idle"
    case .offline:
      "Offline"
    }
  }

  fileprivate var statusBackground: Color {
    switch store.connectionState {
    case .online:
      MonitorTheme.success
    case .connecting:
      MonitorTheme.caution
    case .idle:
      MonitorTheme.accent
    case .offline:
      MonitorTheme.danger
    }
  }

  fileprivate var daemonProjectCount: Int {
    store.daemonStatus?.projectCount ?? store.projects.count
  }

  fileprivate var daemonSessionCount: Int {
    store.daemonStatus?.sessionCount ?? store.sessions.count
  }

  fileprivate var daemonLaunchdState: String {
    store.daemonStatus?.launchAgent.installed == true ? "Installed" : "Manual"
  }

  fileprivate var daemonProjectsBadge: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Projects")) {
      statBadge(title: "Projects", value: "\(daemonProjectCount)")
    }
  }

  fileprivate var daemonSessionsBadge: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Sessions")) {
      statBadge(title: "Sessions", value: "\(daemonSessionCount)")
    }
  }

  fileprivate var daemonLaunchdBadge: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Launchd")) {
      statBadge(title: "Launchd", value: daemonLaunchdState)
    }
  }

  fileprivate func statBadge(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.callout, design: .rounded, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(minHeight: 44, alignment: .topLeading)
    .padding(.vertical, 4)
    .padding(.horizontal, 10)
    .background(
      MonitorTheme.surface,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(MonitorTheme.controlBorder, lineWidth: 1)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(MonitorAccessibility.sidebarDaemonBadge(title))
  }

  fileprivate func labelChip(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(MonitorTheme.surface, in: Capsule())
  }

  fileprivate func sidebarLayoutProbe<Content: View>(
    _ identifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ZStack(alignment: .topLeading) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}
