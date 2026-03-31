import HarnessKit
import SwiftUI

struct SessionCockpitHeaderCard: View {
  let store: HarnessStore
  let detail: SessionDetail

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Circle()
              .fill(statusColor(for: detail.session.status))
              .frame(width: 12, height: 12)
              .accessibilityHidden(true)
            Text(detail.session.context)
              .font(.system(size: 32, weight: .black, design: .rounded))
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

      Group {
        if store.isSessionActionInFlight || store.isSelectionLoading {
          HarnessLoadingStateView(title: "Refreshing live session detail")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: store.isSessionActionInFlight)
      .animation(.spring(duration: 0.3), value: store.isSelectionLoading)

      if let observer = detail.observer {
        observerSummary(observer)
          .transition(.opacity)
      }

      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        pendingTransferSummary(pendingTransfer)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.spring(duration: 0.3), value: detail.observer != nil)
    .animation(.spring(duration: 0.3), value: detail.session.pendingLeaderTransfer != nil)
  }

  private var observeButton: some View {
    Button("Observe", action: observeSelectedSession)
      .font(.system(.subheadline, design: .rounded, weight: .semibold))
      .harnessActionButtonStyle(
        variant: .prominent,
        tint: HarnessTheme.accent
      )
      .controlSize(HarnessControlMetrics.compactControlSize)
  }

  private var endSessionButton: some View {
    Button("End Session", action: store.requestEndSelectedSessionConfirmation)
      .font(.system(.subheadline, design: .rounded, weight: .semibold))
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessTheme.ink)
      .controlSize(HarnessControlMetrics.compactControlSize)
      .accessibilityIdentifier(HarnessAccessibility.endSessionButton)
  }

  private func observerSummary(_ observer: ObserverSummary) -> some View {
    Button {
      store.inspectObserver()
    } label: {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 16) {
          summaryLabel("Observe", value: observer.observeId)
          summaryLabel("Open Issues", value: "\(observer.openIssueCount)")
          summaryLabel("Muted", value: "\(observer.mutedCodeCount)")
          summaryLabel("Workers", value: "\(observer.activeWorkerCount)")
          Spacer()
          summaryLabel("Last Sweep", value: formatTimestamp(observer.lastScanTime))
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
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .harnessInteractiveCardButtonStyle()
    .accessibilityIdentifier("harness.session.observe.summary")
    .accessibilityValue("interactive=plain")
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
    .padding(.leading, 18)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(HarnessTheme.warmAccent)
        .frame(width: 4)
    }
    .accessibilityIdentifier(HarnessAccessibility.pendingLeaderTransferCard)
  }

  private func summaryLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.callout, design: .rounded, weight: .semibold))
    }
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }
}
