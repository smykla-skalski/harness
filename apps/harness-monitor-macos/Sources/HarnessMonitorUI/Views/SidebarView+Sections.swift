import HarnessMonitorKit
import SwiftUI

extension SidebarView {
  func projectSection(
    for group: HarnessMonitorStore.SessionGroup
  ) -> some View {
    Section(isExpanded: projectExpansionBinding(for: group)) {
      ForEach(group.checkoutGroups) { checkoutGroup in
        checkoutDisclosureRow(
          for: checkoutGroup,
          projectID: group.project.projectId
        )
      }
    } header: {
      projectHeader(for: group)
    }
  }

  func projectHeader(
    for group: HarnessMonitorStore.SessionGroup
  ) -> some View {
    Text(group.project.name)
      .font(scaledSidebarFont(.system(.headline, design: .rounded, weight: .semibold)))
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.projectHeader(group.project.projectId)
      )
      .accessibilityFrameMarker(
        HarnessMonitorAccessibility.projectHeaderFrame(group.project.projectId)
      )
  }

  func checkoutDisclosureRow(
    for group: HarnessMonitorStore.CheckoutGroup,
    projectID: String
  ) -> some View {
    DisclosureGroup(isExpanded: checkoutExpansionBinding(for: group, projectID: projectID)) {
      ForEach(group.sessions, id: \.sessionId) { session in
        sessionRow(session)
      }
    } label: {
      checkoutHeader(for: group)
    }
    .selectionDisabled(true)
  }

  func checkoutHeader(
    for group: HarnessMonitorStore.CheckoutGroup
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: group.isWorktree ? "square.3.layers.3d.down.right" : "folder")
        .font(scaledSidebarFont(.caption.weight(.semibold)))
        .foregroundStyle(.secondary)
      Text(group.title)
        .font(scaledSidebarFont(.caption.weight(.semibold)))
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(group.sessionCount)")
        .font(scaledSidebarFont(.caption2.monospacedDigit()))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.worktreeHeader(group.checkoutId)
    )
    .accessibilityFrameMarker(
      HarnessMonitorAccessibility.worktreeHeaderFrame(group.checkoutId)
    )
  }

  @ViewBuilder
  func sessionRow(_ session: SessionSummary) -> some View {
    let row = SidebarSessionListLinkRow(
      session: session,
      isBookmarked: sidebarUI.bookmarkedSessionIds.contains(session.sessionId)
    )
    .equatable()

    let baseRow =
      row
      .tag(session.sessionId as String?)
      .accessibilityLabel(sessionAccessibilityLabel(for: session))
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionRow(session.sessionId))

    if sidebarUI.isPersistenceAvailable {
      baseRow
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowFrame(session.sessionId)
        )
        .accessibilityAction(named: "Toggle Bookmark") {
          store.toggleBookmark(
            sessionId: session.sessionId,
            projectId: session.projectId
          )
        }
        .contextMenu {
          Button {
            store.toggleBookmark(
              sessionId: session.sessionId,
              projectId: session.projectId
            )
          } label: {
            if sidebarUI.bookmarkedSessionIds.contains(session.sessionId) {
              Label("Remove Bookmark", systemImage: "bookmark.slash")
            } else {
              Label("Bookmark", systemImage: "bookmark")
            }
          }
          Divider()
          Button {
            HarnessMonitorClipboard.copy(session.title)
          } label: {
            Label("Copy Title", systemImage: "doc.on.doc")
          }
          .disabled(session.title.isEmpty)
          Button {
            HarnessMonitorClipboard.copy(session.sessionId)
          } label: {
            Label("Copy Session ID", systemImage: "doc.on.doc")
          }
        }
    } else {
      baseRow
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowFrame(session.sessionId)
        )
    }
  }

  func projectExpansionBinding(
    for group: HarnessMonitorStore.SessionGroup
  ) -> Binding<Bool> {
    let projectID = group.project.projectId
    return Binding(
      get: { !collapsedProjectIDs.contains(projectID) },
      set: { isExpanded in
        setProjectCollapsed(projectID: projectID, isCollapsed: !isExpanded)
      }
    )
  }

  func checkoutExpansionBinding(
    for group: HarnessMonitorStore.CheckoutGroup,
    projectID: String
  ) -> Binding<Bool> {
    let checkoutKey = checkoutStorageKey(
      projectID: projectID,
      checkoutID: group.checkoutId
    )
    return Binding(
      get: { !collapsedCheckoutKeys.contains(checkoutKey) },
      set: { isExpanded in
        setCheckoutCollapsed(checkoutKey: checkoutKey, isCollapsed: !isExpanded)
      }
    )
  }

  func checkoutStorageKey(
    projectID: String,
    checkoutID: String
  ) -> String {
    "\(projectID)::\(checkoutID)"
  }
}
