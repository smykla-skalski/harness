import HarnessMonitorKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
          dashboardMetric(
            title: "Tracked Projects",
            value: "\(store.projects.count)",
            tint: MonitorTheme.accent
          )
          dashboardMetric(
            title: "Indexed Sessions",
            value: "\(store.sessions.count)",
            tint: MonitorTheme.success
          )
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
