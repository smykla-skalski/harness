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

  @ViewBuilder
  func checkoutDisclosureRow(
    for group: HarnessMonitorStore.CheckoutGroup,
    projectID: String
  ) -> some View {
    let expansion = checkoutExpansionBinding(for: group, projectID: projectID)

    checkoutHeader(
      for: group,
      isExpanded: expansion.wrappedValue
    ) {
      expansion.wrappedValue.toggle()
    }
    .selectionDisabled(true)

    if expansion.wrappedValue {
      ForEach(group.sessions, id: \.sessionId) { session in
        sessionRow(session)
      }
    }
  }

  func checkoutHeader(
    for group: HarnessMonitorStore.CheckoutGroup,
    isExpanded: Bool,
    toggle: @escaping () -> Void
  ) -> some View {
    SidebarCheckoutDisclosureHeader(
      group: group,
      isExpanded: isExpanded,
      iconFont: scaledSidebarFont(.caption.weight(.semibold)),
      titleFont: scaledSidebarFont(.caption.weight(.semibold)),
      countFont: scaledSidebarFont(.caption2.monospacedDigit()),
      toggle: toggle
    )
  }

  @ViewBuilder
  func sessionRow(_ session: SessionSummary) -> some View {
    let isSelected = sidebarUI.selectedSessionID == session.sessionId
    let row = SidebarSessionListLinkRow(
      session: session,
      isBookmarked: sidebarUI.bookmarkedSessionIds.contains(session.sessionId),
      isSelected: isSelected
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
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowSelectionFrame(session.sessionId),
          when: isSelected
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
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowSelectionFrame(session.sessionId),
          when: isSelected
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

private extension View {
  @ViewBuilder
  func accessibilityFrameMarker(_ identifier: String, when condition: Bool) -> some View {
    if condition {
      accessibilityFrameMarker(identifier)
    } else {
      self
    }
  }
}

private struct SidebarCheckoutDisclosureHeader: View {
  let group: HarnessMonitorStore.CheckoutGroup
  let isExpanded: Bool
  let iconFont: Font
  let titleFont: Font
  let countFont: Font
  let toggle: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        Image(systemName: leadingIconName)
          .font(iconFont)
          .foregroundStyle(.secondary)
          .frame(width: Self.leadingIconWidth, alignment: .leading)
          .accessibilityHidden(true)
        Text(group.title)
          .font(titleFont)
          .foregroundStyle(.secondary)
        Spacer()
        Text("\(group.sessionCount)")
          .font(countFont)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.worktreeHeader(group.checkoutId)
    )
    .accessibilityFrameMarker(
      HarnessMonitorAccessibility.worktreeHeaderFrame(group.checkoutId)
    )
    .help(isExpanded ? "Collapse sessions" : "Expand sessions")
  }

  private var leadingIconName: String {
    if !isExpanded {
      return "chevron.right"
    }
    if isHovered {
      return "chevron.down"
    }
    return group.isWorktree ? "square.3.layers.3d.down.right" : "folder"
  }

  private static let leadingIconWidth: CGFloat = HarnessMonitorTheme.spacingLG
}
