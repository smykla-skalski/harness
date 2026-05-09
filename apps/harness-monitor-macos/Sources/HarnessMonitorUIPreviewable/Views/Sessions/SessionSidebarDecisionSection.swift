import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  @ViewBuilder var decisionsSection: some View {
    Section {
      decisionFilterRow
      undoToastRow
      let orderedDecisionIDs = decisions.map(\.id)
      ForEach(decisions) { decision in
        let selection = SessionSelection.decision(
          sessionID: state.sessionID,
          decisionID: decision.id
        )
        let severity = DecisionSeverity(rawValue: decision.severityRaw)
        SessionSidebarRow(
          title: decision.summary,
          systemImage: "exclamationmark.bubble",
          severityShape: severityShape(for: severity),
          severityTint: severityTint(for: severity)
        )
        .tag(selection)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarDecisionRow(decision.id))
        .simultaneousGesture(
          SpatialTapGesture().onEnded { _ in
            collapseToRowFromPlainTap(selection)
          },
          including: hasActiveMultiSelection ? .gesture : []
        )
        .contextMenu {
          let scope = SessionSidebarContextMenuScope.resolve(
            kind: .decision,
            rowID: decision.id,
            selectedIDs: state.sidebarSelection.selectedDecisionIDs,
            orderedVisibleIDs: orderedDecisionIDs
          )
          Button(scope.destructiveLabel) {
            dismissDecisions(scope.ids)
          }
          Divider()
          Button(scope.copyIDsLabel) {
            HarnessMonitorClipboard.copy(scope.clipboardText)
          }
        }
      }
      if decisions.isEmpty {
        Text("No pending decisions")
          .foregroundStyle(.secondary)
      }
    } header: {
      decisionsHeader
    }
  }

  var decisionsHeader: some View {
    HStack(spacing: 6) {
      Text("Decisions")
        .badge(Text("\(decisions.count) pending"))
      if state.sectionState.hasDraft(.decision) {
        Image(systemName: "circle.fill")
          .font(.caption2)
          .foregroundStyle(.tint)
          .accessibilityLabel("Unsaved draft")
      }
      Spacer()
      Menu {
        Button("Dismiss Selected") {
          dismissDecisions(Array(state.sidebarSelection.selectedDecisionIDs))
        }
        .disabled(state.sidebarSelection.selectedDecisionIDs.isEmpty)
        Button("Dismiss All Visible") {
          dismissDecisions(decisions.map(\.id))
        }
        .disabled(decisions.isEmpty)
        .help(SessionDecisionBulkActionCopy.dismissVisibleHelp)
        if !state.decisionBulkActions.lastDismissedBatch.isEmpty {
          Button("Reopen Dismissed Batch") {
            Task { await reopenDecisionBatch(state.decisionBulkActions.lastDismissedBatch) }
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuIndicator(.hidden)
      .help("Decision Bulk Actions")
      .accessibilityLabel("Decision Bulk Actions")
      Button {
        state.selectCreate(.decision)
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help("New Decision")
      .accessibilityLabel("New Decision")
    }
  }

  var decisionFilterRow: some View {
    SessionDecisionFilterControls(filters: state.decisionFilters)
  }

  @ViewBuilder var undoToastRow: some View {
    if let toast = state.decisionBulkActions.undoToast {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: "arrow.uturn.backward.circle")
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 1) {
          Text(toast.dismissedCopy)
            .lineLimit(1)
          Text(SessionDecisionUndoToastState.commitBarrierCopy)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        Button("Undo") {
          state.decisionBulkActions.requestUndoToastReopen()
        }
        .buttonStyle(.link)
        .keyboardShortcut("z", modifiers: .command)
      }
      .font(.caption)
      .padding(.vertical, HarnessMonitorTheme.spacingXS)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(toast.accessibilityCopy)
      .task(id: toast.id) {
        let delay = max(0, Int((toast.expiresAt.timeIntervalSinceNow * 1000).rounded(.up)))
        try? await Task.sleep(for: .milliseconds(delay))
        await MainActor.run {
          state.decisionBulkActions.clearExpiredUndoToast()
        }
      }
    }
  }
}
