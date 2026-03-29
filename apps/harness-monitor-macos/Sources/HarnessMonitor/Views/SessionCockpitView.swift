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
            .foregroundStyle(MonitorTheme.secondaryInk)
        }
        Spacer()
        HStack(spacing: 10) {
          observeButton
          endSessionButton
        }
      }

      if store.isSessionActionInFlight || store.isSelectionLoading {
        MonitorLoadingStateView(title: "Refreshing live session detail")
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if let observer = detail.observer {
        observerSummary(observer)
      }

      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        pendingTransferSummary(pendingTransfer)
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
    .monitorActionButtonStyle(variant: .prominent, tint: MonitorTheme.accent)
  }

  private var endSessionButton: some View {
    Button {
      store.requestEndSelectedSessionConfirmation()
    } label: {
      actionLabel("End Session")
    }
    .monitorActionButtonStyle(variant: .bordered, tint: MonitorTheme.ink)
    .accessibilityIdentifier(MonitorAccessibility.endSessionButton)
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
            .foregroundStyle(MonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
          Text("Muted: \(mutedCodes.prefix(3).joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(MonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background {
        MonitorInteractiveCardBackground(cornerRadius: 18, tint: nil)
      }
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("monitor.session.observe.summary")
  }

  private var signalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Signals")
        .font(.system(.title3, design: .serif, weight: .semibold))
      MonitorGlassContainer(spacing: 12) {
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
                  .foregroundStyle(MonitorTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 6) {
                Text(signal.status.title)
                  .font(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(MonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
              MonitorInteractiveCardBackground(cornerRadius: 18, tint: nil)
            }
          }
          .buttonStyle(.plain)
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.95).combined(with: .opacity),
              removal: .opacity
            ))
        }
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
              .foregroundStyle(MonitorTheme.secondaryInk)
          }
          Spacer()
          if let taskID = entry.taskId {
            Text(taskID)
              .font(.caption.monospaced())
              .foregroundStyle(MonitorTheme.secondaryInk)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
          MonitorInsetPanelBackground(
            cornerRadius: 16,
            fillOpacity: 0.05,
            strokeOpacity: 0.10
          )
        }
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .opacity
          ))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private func pendingTransferSummary(_ pendingTransfer: PendingLeaderTransfer) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Pending Leader Transfer", systemImage: "arrow.left.arrow.right")
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        Text(formatTimestamp(pendingTransfer.requestedAt))
          .font(.caption.monospaced())
          .foregroundStyle(MonitorTheme.secondaryInk)
      }
      let requested = pendingTransfer.requestedBy
      let newLeader = pendingTransfer.newLeaderId
      let current = pendingTransfer.currentLeaderId
      Text("\(requested) requested \(newLeader) to replace \(current).")
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(MonitorTheme.secondaryInk)
      if let reason = pendingTransfer.reason, !reason.isEmpty {
        Text(reason)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(MonitorTheme.warmAccent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background {
      MonitorInsetPanelBackground(
        cornerRadius: 18,
        fillOpacity: 0.06,
        strokeOpacity: 0.12
      )
    }
    .accessibilityIdentifier(MonitorAccessibility.pendingLeaderTransferCard)
  }

  private func label(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(MonitorTheme.secondaryInk)
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
