import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardCardContextMenuActions {
  let selectedIDs: Set<TaskBoardCardID>
  let orderedVisibleIDs: [TaskBoardCardID]
  let isActionInFlight: Bool
  let canOpen: (TaskBoardCardID) -> Bool
  let open: (TaskBoardCardID) -> Void
  let canOpenAgent: (TaskBoardCardID) -> Bool
  let openAgent: (TaskBoardCardID) -> Void
  let githubURL: (TaskBoardCardID) -> URL?
  let openGitHubURL: (URL) -> Void
  let canMove: ([TaskBoardCardID], TaskBoardInboxLane) -> Bool
  let move: ([TaskBoardCardID], TaskBoardInboxLane) -> Void
  let deletionTargets: ([TaskBoardCardID]) -> [TaskBoardDeletionTarget]
  let canDelete: ([TaskBoardCardID]) -> Bool
  let deleteTargets: (([TaskBoardDeletionTarget]) -> Void)?
  let primeSelection: ([TaskBoardCardID]) -> Void
}

extension TaskBoardCardContextMenuActions {
  /// Environment default before `TaskBoardOverviewView` installs the real
  /// value. Never rendered live: `.contextMenu` content is only built when a
  /// menu actually opens, by which point the environment carries the real
  /// actions - this only backstops previews/tests that mount a card in
  /// isolation, so every branch is disabled/no-op.
  static var inert: TaskBoardCardContextMenuActions {
    TaskBoardCardContextMenuActions(
      selectedIDs: [],
      orderedVisibleIDs: [],
      isActionInFlight: true,
      canOpen: { _ in false },
      open: { _ in },
      canOpenAgent: { _ in false },
      openAgent: { _ in },
      githubURL: { _ in nil },
      openGitHubURL: { _ in },
      canMove: { _, _ in false },
      move: { _, _ in },
      deletionTargets: { _ in [] },
      canDelete: { _ in false },
      deleteTargets: nil,
      primeSelection: { _ in }
    )
  }
}

extension EnvironmentValues {
  @Entry var taskBoardCardContextMenuActions: TaskBoardCardContextMenuActions = .inert
}

struct TaskBoardCardContextMenu: View {
  let cardID: TaskBoardCardID
  @Environment(\.taskBoardCardContextMenuActions)
  private var actions

  var body: some View {
    if let scope = TaskBoardCardContextMenuScope.resolve(
      menuSelection: [cardID],
      selectedIDs: actions.selectedIDs,
      orderedVisibleIDs: actions.orderedVisibleIDs
    ) {
      menuContent(scope: scope)
        .onAppear {
          actions.primeSelection(scope.cardIDs)
        }
    }
  }

  @ViewBuilder
  private func menuContent(scope: TaskBoardCardContextMenuScope) -> some View {
    if scope.isSingle {
      Button("Open") {
        actions.open(scope.primaryID)
      }
      .disabled(!actions.canOpen(scope.primaryID))
      if actions.canOpenAgent(scope.primaryID) {
        Button {
          actions.openAgent(scope.primaryID)
        } label: {
          Label("Open Agent", systemImage: "arrow.up.forward.app")
        }
      }
      if let githubURL = actions.githubURL(scope.primaryID) {
        Button {
          actions.openGitHubURL(githubURL)
        } label: {
          Label("Open on GitHub", systemImage: "arrow.up.right.square")
        }
      }
    }
    Button(scope.copyIDsLabel) {
      HarnessMonitorClipboard.copy(scope.clipboardText)
    }
    Divider()
    Menu("Move to...") {
      ForEach(TaskBoardInboxLane.allCases) { lane in
        Button {
          actions.move(scope.cardIDs, lane)
        } label: {
          Label(lane.title, systemImage: lane.systemImage)
        }
        .disabled(!actions.canMove(scope.cardIDs, lane))
      }
    }
    .disabled(actions.isActionInFlight)
    Divider()
    deleteButton(scope: scope)
  }

  @ViewBuilder
  private func deleteButton(scope: TaskBoardCardContextMenuScope) -> some View {
    let targets = actions.deletionTargets(scope.cardIDs)
    Button(scope.deleteLabel, role: .destructive) {
      actions.deleteTargets?(targets)
    }
    .disabled(
      actions.isActionInFlight
        || actions.deleteTargets == nil
        || !actions.canDelete(scope.cardIDs)
        || targets.count != scope.count
    )
  }
}
