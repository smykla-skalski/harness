import HarnessMonitorKit
import SwiftUI

extension SidebarSessionListContent {
  private var orderedVisibleSessions: [SessionSummary] {
    renderState.searchVisibleSessionIDs.compactMap { sessionID in
      renderState.sessionSummary(for: sessionID)
    }
  }

  private func sessionContextMenuScope(
    for session: SessionSummary
  ) -> SidebarSessionContextMenuScope {
    SidebarSessionContextMenuScope.resolve(
      rowSession: session,
      selectedSessionIDs: renderState.selectedSessionIDs,
      orderedVisibleSessions: orderedVisibleSessions,
      bookmarkedSessionIDs: renderState.bookmarkedSessionIDs
    )
  }

  private func applyBookmarkAction(_ scope: SidebarSessionContextMenuScope) {
    for target in scope.bookmarkTargets {
      toggleBookmark(target.sessionID, target.projectID)
    }
  }

  @ViewBuilder
  func sessionContextMenu(for session: SessionSummary) -> some View {
    let scope = sessionContextMenuScope(for: session)
    if renderState.isPersistenceAvailable {
      Button {
        applyBookmarkAction(scope)
      } label: {
        Label(scope.bookmarkLabel, systemImage: scope.bookmarkSystemImage)
      }
      Divider()
    }
    Button {
      HarnessMonitorClipboard.copy(scope.copyTitleText)
    } label: {
      Label(scope.copyTitleLabel, systemImage: "doc.on.doc")
    }
    .disabled(!scope.canCopyTitles)
    Button {
      HarnessMonitorClipboard.copy(scope.copySessionIDText)
    } label: {
      Label(scope.copySessionIDLabel, systemImage: "doc.on.doc")
    }
    Divider()
    Button(role: .destructive) {
      store.requestRemoveSessionConfirmation(sessionIDs: scope.sessionIDs)
    } label: {
      Label(scope.removeLabel, systemImage: "trash")
    }
  }
}
