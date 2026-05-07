import HarnessMonitorKit
import SwiftUI

extension SessionSidebar {
  @ViewBuilder var decisionsSection: some View {
    Section {
      decisionFilterRow
      ForEach(decisions) { decision in
        let severity = DecisionSeverity(rawValue: decision.severityRaw)
        SessionSidebarRow(
          title: decision.summary,
          systemImage: "exclamationmark.bubble",
          severityShape: severityShape(for: severity),
          severityTint: severityTint(for: severity),
          isDropTargeted: decisionDropTargetID == decision.id,
          isMultiSelect: state.sidebarSelection.isDecisionMultiSelectEnabled,
          isSelected: state.sidebarSelection.selectedDecisionIDs.contains(decision.id),
          toggleSelection: {
            state.sidebarSelection.toggleDecision(decision.id)
          }
        )
        .tag(SessionSelection.decision(sessionID: state.sessionID, decisionID: decision.id))
        .dropDestination(for: TaskDragPayload.self) { payloads, _ in
          handleTaskDecisionDrop(payloads, decisionID: decision.id)
        } isTargeted: { isTargeted in
          decisionDropTargetID = isTargeted ? decision.id : nil
        }
        .contextMenu {
          Button("Dismiss Decision") {
            dismissDecisions([decision.id])
          }
          Divider()
          Button("Copy Decision ID") {
            HarnessMonitorClipboard.copy(decision.id)
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
        .help("Dismisses only the decisions that match the current filter and search.")
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
        state.sidebarSelection.toggleDecisionMultiSelect()
      } label: {
        Image(
          systemName: state.sidebarSelection.isDecisionMultiSelectEnabled
            ? "checkmark.circle.fill"
            : "checkmark.circle"
        )
      }
      .buttonStyle(.borderless)
      .help("Select Decisions")
      .accessibilityLabel("Select Decisions")
      .accessibilityValue(multiSelectAccessibilityValue)
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

  var multiSelectAccessibilityValue: Text {
    guard state.sidebarSelection.isDecisionMultiSelectEnabled else {
      return Text("Off")
    }
    let count = state.sidebarSelection.selectedDecisionIDs.count
    return Text("\(count) decision\(count == 1 ? "" : "s") selected")
  }
}

@MainActor
public enum SessionSidebarMultiSelectAnnouncer {
  private static var pendingTask: Task<Void, Never>?
  private static let debounceInterval: Duration = .milliseconds(150)

  public static func announce(count: Int) {
    pendingTask?.cancel()
    pendingTask = Task { @MainActor in
      try? await Task.sleep(for: debounceInterval)
      guard !Task.isCancelled else { return }
      let suffix = count == 1 ? "" : "s"
      AccessibilityNotification.Announcement(
        "\(count) decision\(suffix) selected"
      ).post()
    }
  }
}
