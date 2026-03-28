import HarnessMonitorKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
        if store.sessions.isEmpty {
          onboardingCard
        }
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
          if store.sessions.isEmpty {
            Text(
              "No sessions indexed yet. Bring the daemon online or refresh after starting a harness session."
            )
            .font(.system(.body, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
          } else {
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

  private var onboardingCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Label("Bring The Monitor Online", systemImage: "dot.radiowaves.left.and.right")
            .font(.system(.title3, design: .rounded, weight: .bold))
          Text(
            "Harness Monitor only reads live state from the local daemon. "
              + "Start the control plane once, then keep it resident with a launch agent."
          )
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
        }
        Spacer()
        Text(store.daemonStatus?.launchAgent.installed == true ? "Persistent" : "Manual")
          .font(.caption.bold())
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(MonitorTheme.accent, in: Capsule())
          .foregroundStyle(.white)
      }

      HStack(spacing: 14) {
        onboardingStep(
          title: "1. Start the daemon",
          detail: "Boot the local HTTP and SSE bridge.",
          isReady: store.connectionState == .online
        )
        onboardingStep(
          title: "2. Install launchd",
          detail: "Keep the daemon available across app restarts.",
          isReady: store.daemonStatus?.launchAgent.installed == true
        )
        onboardingStep(
          title: "3. Start a harness session",
          detail: "Sessions appear here as soon as the daemon indexes them.",
          isReady: !store.sessions.isEmpty
        )
      }

      HStack(spacing: 12) {
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

        Button("Refresh Index") {
          Task {
            await store.refresh()
          }
        }
        .buttonStyle(.bordered)
      }
    }
    .monitorCard()
    .accessibilityIdentifier(MonitorAccessibility.onboardingCard)
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

  private func onboardingStep(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Circle()
          .fill(isReady ? MonitorTheme.success : MonitorTheme.caution)
          .frame(width: 10, height: 10)
        Text(title)
          .font(.system(.headline, design: .rounded, weight: .semibold))
      }
      Text(detail)
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
      Text(isReady ? "Ready" : "Pending")
        .font(.caption.bold())
        .foregroundStyle(isReady ? MonitorTheme.success : MonitorTheme.caution)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
  }
}
