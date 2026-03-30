import HarnessKit
import Observation
import SwiftUI

struct SessionCockpitView: View {
  @Bindable var store: HarnessStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(store: store, detail: detail)
        HarnessAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
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
    .foregroundStyle(HarnessTheme.ink)
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
              .accessibilityHidden(true)
            Text(detail.session.context)
              .font(.system(size: 32, weight: .black, design: .serif))
          }
          Text("\(detail.session.projectName) • \(detail.session.sessionId)")
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        Spacer()
        HStack(spacing: 10) {
          observeButton
          endSessionButton
        }
      }

      if store.isSessionActionInFlight || store.isSelectionLoading {
        HarnessLoadingStateView(title: "Refreshing live session detail")
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
    .harnessCard()
  }

  private var observeButton: some View {
    Button {
      Task {
        await store.observeSelectedSession()
      }
    } label: {
      actionLabel("Observe")
    }
    .harnessActionButtonStyle(variant: .prominent, tint: HarnessTheme.accent)
  }

  private var endSessionButton: some View {
    Button {
      store.requestEndSelectedSessionConfirmation()
    } label: {
      actionLabel("End Session")
    }
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessTheme.ink)
    .accessibilityIdentifier(HarnessAccessibility.endSessionButton)
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
            .foregroundStyle(HarnessTheme.secondaryInk)
            .lineLimit(1)
        }
        if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
          Text("Muted: \(mutedCodes.prefix(3).joined(separator: ", "))")
            .font(.caption)
            .foregroundStyle(HarnessTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background {
        HarnessInteractiveCardBackground(cornerRadius: 18, tint: nil)
      }
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("harness.session.observe.summary")
  }

  private var signalsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Signals")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HarnessGlassContainer(spacing: 12) {
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
                  .foregroundStyle(HarnessTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: 6) {
                Text(signal.status.title)
                  .font(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
              HarnessInteractiveCardBackground(cornerRadius: 18, tint: nil)
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
    .harnessCard()
  }

  private var timelineSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Timeline")
        .font(.system(.title3, design: .serif, weight: .semibold))
      ForEach(timeline) { entry in
        HStack(alignment: .top, spacing: 12) {
          RoundedRectangle(cornerRadius: 999)
            .fill(HarnessTheme.accent.opacity(0.35))
            .frame(width: 8)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.summary)
              .font(.system(.body, design: .rounded, weight: .semibold))
            Text("\(entry.kind) • \(formatTimestamp(entry.recordedAt))")
              .font(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          Spacer()
          if let taskID = entry.taskId {
            Text(taskID)
              .font(.caption.monospaced())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
          HarnessInsetPanelBackground(
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
    .harnessCard()
  }

  private func pendingTransferSummary(_ pendingTransfer: PendingLeaderTransfer) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Pending Leader Transfer", systemImage: "arrow.left.arrow.right")
          .font(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        Text(formatTimestamp(pendingTransfer.requestedAt))
          .font(.caption.monospaced())
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
      let requested = pendingTransfer.requestedBy
      let newLeader = pendingTransfer.newLeaderId
      let current = pendingTransfer.currentLeaderId
      Text("\(requested) requested \(newLeader) to replace \(current).")
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
      if let reason = pendingTransfer.reason, !reason.isEmpty {
        Text(reason)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessTheme.warmAccent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 18,
        fillOpacity: 0.06,
        strokeOpacity: 0.12
      )
    }
    .accessibilityIdentifier(HarnessAccessibility.pendingLeaderTransferCard)
  }

  private func label(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
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

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessStore(daemonController: PreviewDaemonController()),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline
  )
}
