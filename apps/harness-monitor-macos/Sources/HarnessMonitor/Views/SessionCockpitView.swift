import HarnessMonitorKit
import Observation
import SwiftUI

struct SessionCockpitView: View {
  @Bindable var store: MonitorStore
  @Bindable var actions: CockpitActionCenter
  let detail: SessionDetail
  let timeline: [TimelineEntry]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        metrics
        SessionActionDock(store: store, actions: actions, detail: detail)
        HStack(alignment: .top, spacing: 16) {
          tasksColumn
          agentsColumn
        }
        signalsSection
        timelineSection
      }
      .padding(24)
    }
    .foregroundStyle(MonitorTheme.ink)
    .background(MonitorTheme.canvas.ignoresSafeArea())
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
        VStack(alignment: .trailing, spacing: 10) {
          Button("Observe") {
            Task {
              await store.observeSelectedSession()
            }
          }
          .buttonStyle(.borderedProminent)
          .tint(MonitorTheme.accent)

          Button("End Session") {
            Task {
              await store.endSelectedSession()
            }
          }
          .buttonStyle(.bordered)
        }
      }

      if let observer = detail.observer {
        Button {
          store.inspectObserver()
        } label: {
          HStack(spacing: 16) {
            label("Observe", value: observer.observeId)
            label("Open Issues", value: "\(observer.openIssueCount)")
            label("Muted", value: "\(observer.mutedCodeCount)")
            label("Workers", value: "\(observer.activeWorkerCount)")
            Spacer()
            label("Last Sweep", value: formatTimestamp(observer.lastScanTime))
          }
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
      }
    }
    .monitorCard()
  }

  private var metrics: some View {
    HStack(spacing: 14) {
      metric(
        title: "Agents",
        value: "\(detail.session.metrics.agentCount)",
        tint: MonitorTheme.accent
      )
      metric(
        title: "Active",
        value: "\(detail.session.metrics.activeAgentCount)",
        tint: MonitorTheme.success
      )
      metric(
        title: "In Flight",
        value: "\(detail.session.metrics.inProgressTaskCount)",
        tint: MonitorTheme.warmAccent
      )
      metric(
        title: "Blocked",
        value: "\(detail.session.metrics.blockedTaskCount)",
        tint: MonitorTheme.danger
      )
      metric(
        title: "Completed",
        value: "\(detail.session.metrics.completedTaskCount)",
        tint: MonitorTheme.ink
      )
    }
  }

  private var tasksColumn: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Tasks")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(detail.tasks) { task in
        Button {
          store.inspect(taskID: task.taskId)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(task.title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
              Spacer()
              Text(task.severity.rawValue.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(severityColor(for: task.severity), in: Capsule())
                .foregroundStyle(.white)
            }
            Text(task.context ?? "No extra context")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.leading)
            HStack {
              Text(task.status.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(taskStatusColor(for: task.status))
              Spacer()
              Text(task.assignedTo ?? "unassigned")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .monitorCard()
  }

  private var agentsColumn: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agents")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(detail.agents) { agent in
        Button {
          store.inspect(agentID: agent.agentId)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text(agent.name)
                .font(.system(.headline, design: .rounded, weight: .semibold))
              Spacer()
              Text(agent.role.rawValue.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MonitorTheme.accent, in: Capsule())
                .foregroundStyle(.white)
            }
            Text("\(agent.runtime) • \(agent.agentId)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            HStack(spacing: 10) {
              badge(agent.runtimeCapabilities.supportsContextInjection ? "Context" : "Watch")
              badge("\(agent.runtimeCapabilities.typicalSignalLatencySeconds)s")
              badge(formatTimestamp(agent.lastActivityAt))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
          .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .monitorCard()
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
                .foregroundStyle(taskStatusColor(for: signalStatusTaskValue(signal.status)))
              Text(formatTimestamp(signal.signal.createdAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
          }
          .padding(14)
          .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
      }
    }
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
        .padding(12)
        .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .monitorCard()
  }

  private func metric(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 28, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Color.white.opacity(0.7), in: Capsule())
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
}

struct SessionActionDock: View {
  @Bindable var store: MonitorStore
  @Bindable var actions: CockpitActionCenter
  let detail: SessionDetail

  private var firstTaskID: String? {
    detail.tasks.first?.taskId
  }

  private var firstAgentID: String? {
    detail.agents.first?.agentId
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Action Flow")
            .font(.system(.headline, design: .rounded, weight: .semibold))
          Text("Pick a lane, then use the inspector to submit the change.")
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          if actions.isBusy {
            ProgressView()
              .controlSize(.small)
          } else if !actions.lastAction.isEmpty {
            Text(actions.lastAction)
              .font(.caption.bold())
              .foregroundStyle(MonitorTheme.success)
          }
          Text("\(detail.tasks.count) tasks · \(detail.agents.count) agents")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 12) {
        flowButton(
          title: "Task Flow",
          subtitle: "Create, reassign, checkpoint",
          symbol: "checklist",
          action: focusFirstTask
        )
        flowButton(
          title: "People Flow",
          subtitle: "Change roles and leadership",
          symbol: "person.2",
          action: focusFirstAgent
        )
        flowButton(
          title: "Observe Flow",
          subtitle: "Surface and triage issues",
          symbol: "eye",
          action: focusObserver
        )
      }
    }
    .monitorCard()
  }

  private func flowButton(
    title: String,
    subtitle: String,
    symbol: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        Label(title, systemImage: symbol)
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(Color.white.opacity(0.56), in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
  }

  private func focusFirstTask() {
    guard let taskID = firstTaskID else {
      return
    }
    store.inspect(taskID: taskID)
  }

  private func focusFirstAgent() {
    guard let agentID = firstAgentID else {
      return
    }
    store.inspect(agentID: agentID)
  }

  private func focusObserver() {
    store.inspectObserver()
  }
}

private func signalStatusTaskValue(_ status: SessionSignalStatus) -> TaskStatus {
  switch status {
  case .pending, .deferred:
    .inProgress
  case .acknowledged:
    .done
  case .rejected, .expired:
    .blocked
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: MonitorStore(daemonController: PreviewDaemonController()),
    actions: CockpitActionCenter(),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline
  )
}
