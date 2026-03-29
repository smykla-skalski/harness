import HarnessMonitorKit
import Observation
import SwiftUI

struct SessionCockpitView: View {
  @Bindable var store: MonitorStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]

  var body: some View {
    MonitorColumnScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(store: store, detail: detail)
        MonitorAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(tasks: detail.tasks) { taskID in
            store.inspect(taskID: taskID)
          }
          SessionAgentListSection(agents: detail.agents) { agentID in
            store.inspect(agentID: agentID)
          }
        }
        signalsSection
        timelineSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(MonitorTheme.ink)
    .animation(.easeInOut(duration: 0.18), value: detail.tasks)
    .animation(.easeInOut(duration: 0.18), value: detail.agents)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Circle()
              .fill(statusColor(for: detail.session.status))
              .frame(width: 12, height: 12)
            Text(detail.session.context)
              .font(.system(size: 32, weight: .black, design: .serif))
          }
          Text("\(detail.session.projectName) • \(detail.session.sessionId)")
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 10) {
          observeButton
          endSessionButton
        }
      }

      if store.isBusy || store.isRefreshing {
        MonitorLoadingStateView(title: "Refreshing live session detail")
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if let observer = detail.observer {
        observerSummary(observer)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private var observeButton: some View {
    Button {
      Task {
        await store.observeSelectedSession()
      }
    } label: {
      actionLabel("Observe")
    }
    .buttonStyle(MonitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.accent))
  }

  private var endSessionButton: some View {
    Button {
      Task {
        await store.endSelectedSession()
      }
    } label: {
      actionLabel("End Session")
    }
    .buttonStyle(MonitorActionButtonStyle(variant: .bordered, tint: MonitorTheme.ink))
  }

  private func observerSummary(_ observer: ObserverSummary) -> some View {
    Button {
      store.inspectObserver()
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 16) {
          label("Observe", value: observer.observeId)
          label("Open Issues", value: "\(observer.openIssueCount)")
          label("Muted", value: "\(observer.mutedCodeCount)")
          label("Workers", value: "\(observer.activeWorkerCount)")
          Spacer()
          label("Last Sweep", value: formatTimestamp(observer.lastScanTime))
        }
        if let openIssues = observer.openIssues, !openIssues.isEmpty {
          Text(openIssues.prefix(2).map(\.summary).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
          Text("Muted: \(mutedCodes.prefix(3).joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("monitor.session.observe.summary")
    .padding(14)
    .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
  }

  private var signalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Signals")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(detail.signals) { signal in
        Button {
          store.inspect(signalID: signal.signal.signalId)
        } label: {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
              Text(signal.signal.command)
                .font(.system(.headline, design: .rounded, weight: .semibold))
              Text(signal.signal.payload.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
              Text(signal.status.rawValue.capitalized)
                .font(.caption.bold())
                .foregroundStyle(signalStatusColor(for: signal.status))
              Text(formatTimestamp(signal.signal.createdAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private var timelineSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Timeline")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(timeline) { entry in
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 999)
            .fill(MonitorTheme.accent.opacity(0.35))
            .frame(width: 8)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.summary)
              .font(.system(.body, design: .rounded, weight: .semibold))
            Text("\(entry.kind) • \(formatTimestamp(entry.recordedAt))")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          Spacer()
          if let taskID = entry.taskId {
            Text(taskID)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private func label(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.callout, design: .rounded, weight: .semibold))
    }
  }

  private func actionLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(.subheadline, design: .rounded, weight: .semibold))
      .multilineTextAlignment(.center)
      .lineLimit(1)
      .frame(minWidth: 110, minHeight: 38)
  }
}

func signalStatusColor(for status: SessionSignalStatus) -> Color {
  switch status {
  case .pending, .deferred:
    MonitorTheme.caution
  case .acknowledged:
    MonitorTheme.success
  case .rejected, .expired:
    MonitorTheme.danger
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: MonitorStore(daemonController: PreviewDaemonController()),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline
  )
}
