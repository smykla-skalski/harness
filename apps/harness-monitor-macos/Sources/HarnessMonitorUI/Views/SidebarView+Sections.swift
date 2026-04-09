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
    .transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
    .listRowInsets(sidebarRowInsets)
  }

  func projectHeader(
    for group: HarnessMonitorStore.SessionGroup
  ) -> some View {
    Text(group.project.name)
      .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
      .foregroundStyle(HarnessMonitorTheme.ink)
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
      ForEach(group.sessions) { session in
        sessionRow(session)
      }
    } label: {
      checkoutHeader(for: group)
    }
    .transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
    .listRowInsets(sidebarRowInsets)
  }

  func checkoutHeader(
    for group: HarnessMonitorStore.CheckoutGroup
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: group.isWorktree ? "square.3.layers.3d.down.right" : "folder")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(group.title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer()
      Text("\(group.sessions.count)")
        .scaledFont(.caption2.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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
    let isSelected = store.selectedSessionID == session.sessionId
    let row = SidebarSessionListLinkRow(
      session: session,
      isBookmarked: store.bookmarkedSessionIds.contains(session.sessionId),
      isSelected: isSelected
    )

    let baseRow = row
      .tag(session.sessionId as String?)
      .accessibilityLabel(sessionAccessibilityLabel(for: session))
      .accessibilityValue(
        sessionAccessibilityValue(
          for: session,
          selectedSessionID: store.selectedSessionID
        )
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionRow(session.sessionId))
      .listRowInsets(sidebarRowInsets)

    if store.isPersistenceAvailable {
      baseRow
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
            if store.bookmarkedSessionIds.contains(session.sessionId) {
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
        .overlay(alignment: .leading) {
          if HarnessMonitorUITestEnvironment.isEnabled {
            row
              .opacity(0.001)
              .allowsHitTesting(false)
              .accessibilityElement(children: .ignore)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.sessionRowFrame(session.sessionId)
              )
          }
        }
    } else {
      baseRow
        .overlay(alignment: .leading) {
          if HarnessMonitorUITestEnvironment.isEnabled {
            row
              .opacity(0.001)
              .allowsHitTesting(false)
              .accessibilityElement(children: .ignore)
              .accessibilityIdentifier(
                HarnessMonitorAccessibility.sessionRowFrame(session.sessionId)
              )
          }
        }
    }
  }

  func projectExpansionBinding(
    for group: HarnessMonitorStore.SessionGroup
  ) -> Binding<Bool> {
    let projectID = group.project.projectId
    return Binding(
      get: { !collapsedProjectIDs.contains(projectID) },
      set: { isExpanded in
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          updateStorageSet(
            &collapsedProjectIDsStorage,
            entry: projectID,
            include: !isExpanded
          )
        }
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
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          updateStorageSet(
            &collapsedCheckoutKeysStorage,
            entry: checkoutKey,
            include: !isExpanded
          )
        }
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
