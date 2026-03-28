import HarnessMonitorKit
import Observation
import SwiftUI

struct ContentView: View {
  @Bindable var store: MonitorStore
  @State private var showsPreferences = false

  private var selectedDetail: SessionDetail? {
    guard let sessionID = store.selectedSessionID,
      let detail = store.selectedSession,
      detail.session.sessionId == sessionID
    else {
      return nil
    }
    return detail
  }

  var body: some View {
    NavigationSplitView {
      SidebarView(store: store)
        .navigationSplitViewColumnWidth(min: 300, ideal: 350)
    } content: {
      Group {
        if let detail = selectedDetail {
          SessionCockpitView(store: store, detail: detail, timeline: store.timeline)
        } else {
          SessionsBoardView(store: store)
        }
      }
      .navigationSplitViewColumnWidth(min: 600, ideal: 840)
    } detail: {
      InspectorColumnView(store: store)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380)
    }
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .searchable(text: $store.searchText, prompt: "Search sessions, projects, leaders")
    .navigationTitle("Harness Monitor")
    .toolbar {
      ToolbarItemGroup {
        Button {
          Task {
            await store.refresh()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: [.command])

        Button {
          showsPreferences.toggle()
        } label: {
          Label("Daemon", systemImage: "gearshape.2")
        }
      }
    }
    .sheet(isPresented: $showsPreferences) {
      PreferencesView(store: store)
        .frame(minWidth: 620, minHeight: 420)
    }
  }
}

private struct SidebarView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      daemonStatusCard
      filterStrip
      sessionList
    }
    .padding(22)
    .foregroundStyle(MonitorTheme.ink)
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

      if let daemonStatus = store.daemonStatus {
        HStack(spacing: 12) {
          statBadge(title: "Projects", value: "\(daemonStatus.projectCount)")
          statBadge(title: "Sessions", value: "\(daemonStatus.sessionCount)")
          statBadge(
            title: "Launchd",
            value: daemonStatus.launchAgent.installed ? "Installed" : "Manual"
          )
        }
      }

      HStack(spacing: 10) {
        Button("Start Daemon") {
          Task {
            await store.startDaemon()
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(MonitorTheme.accent)

        Button("Install Launch Agent") {
          Task {
            await store.installLaunchAgent()
          }
        }
        .buttonStyle(.bordered)
      }
    }
    .monitorCard()
  }

  private var filterStrip: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Scope")
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Picker("Session Filter", selection: $store.sessionFilter) {
        ForEach(MonitorStore.SessionFilter.allCases) { filter in
          Text(filter.rawValue.capitalized).tag(filter)
        }
      }
      .pickerStyle(.segmented)
    }
    .monitorCard()
  }

  private var sessionList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ForEach(store.groupedSessions) { group in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(group.project.name)
                .font(.system(.headline, design: .serif, weight: .semibold))
              Spacer()
              Text("\(group.sessions.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ForEach(group.sessions) { session in
              Button {
                Task {
                  await store.selectSession(session.sessionId)
                }
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  HStack {
                    Text(session.context)
                      .font(.system(.body, design: .rounded, weight: .semibold))
                      .multilineTextAlignment(.leading)
                    Spacer()
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                  RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                      store.selectedSessionID == session.sessionId
                        ? Color.white.opacity(0.82) : Color.white.opacity(0.46)
                    )
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .monitorCard()
  }

  private var connectionLabel: String {
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

  private var statusPill: some View {
    Text(statusTitle)
      .font(.caption.bold())
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(statusBackground, in: Capsule())
      .foregroundStyle(.white)
  }

  private var statusTitle: String {
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

  private var statusBackground: Color {
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

  private func statBadge(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .bold))
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
  }

  private func labelChip(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.white.opacity(0.62), in: Capsule())
  }
}

private struct SessionsBoardView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
          dashboardMetric(
            title: "Tracked Projects", value: "\(store.projects.count)", tint: MonitorTheme.accent)
          dashboardMetric(
            title: "Indexed Sessions", value: "\(store.sessions.count)", tint: MonitorTheme.success)
          dashboardMetric(
            title: "Open Work",
            value: "\(store.sessions.reduce(0) { $0 + $1.metrics.openTaskCount })",
            tint: MonitorTheme.warmAccent
          )
          dashboardMetric(
            title: "Blocked",
            value: "\(store.sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount })",
            tint: MonitorTheme.danger
          )
        }

        VStack(alignment: .leading, spacing: 14) {
          Text("Recent Sessions")
            .font(.system(.title3, design: .serif, weight: .semibold))
          ForEach(store.sessions.prefix(8)) { session in
            Button {
              Task {
                await store.selectSession(session.sessionId)
              }
            } label: {
              HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(statusColor(for: session.status))
                  .frame(width: 10)
                VStack(alignment: .leading, spacing: 4) {
                  Text(session.context)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .multilineTextAlignment(.leading)
                  Text("\(session.projectName) • \(session.sessionId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatTimestamp(session.updatedAt))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
              }
              .padding(14)
              .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
          }
        }
        .monitorCard()
      }
      .padding(24)
    }
    .foregroundStyle(MonitorTheme.ink)
    .background(MonitorTheme.canvas.ignoresSafeArea())
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Harness Monitor")
        .font(.system(size: 42, weight: .black, design: .serif))
      Text(
        "A live control deck for harness daemon sessions, task flow, runtimes, and signal latency."
      )
      .font(.system(.title3, design: .rounded, weight: .medium))
      .foregroundStyle(.secondary)
      if let lastError = store.lastError {
        Text(lastError)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(MonitorTheme.danger)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private func dashboardMetric(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 34, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }
}

#Preview("Dashboard") {
  ContentView(store: MonitorStore(daemonController: PreviewDaemonController()))
}
