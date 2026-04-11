import HarnessMonitorKit
import SwiftUI

struct SidebarSessionListRenderState: Equatable {
  let projectionGroups: [HarnessMonitorStore.SessionGroup]
  let searchPresentation: HarnessMonitorStore.SessionSearchPresentationState
  let searchList: HarnessMonitorStore.SessionSearchResultsListState
  let selectedSessionID: String?
  let bookmarkedSessionIDs: Set<String>
  let isPersistenceAvailable: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedProjectIDs: Set<String>
  let collapsedCheckoutKeys: Set<String>

  var emptyState: HarnessMonitorStore.SidebarEmptyState {
    searchPresentation.emptyState
  }

  var usesFlatSearchResults: Bool {
    searchPresentation.isSearchActive
  }

  func isProjectExpanded(_ projectID: String) -> Bool {
    !collapsedProjectIDs.contains(projectID)
  }

  func isCheckoutExpanded(
    projectID: String,
    checkoutID: String
  ) -> Bool {
    !collapsedCheckoutKeys.contains(Self.checkoutStorageKey(projectID: projectID, checkoutID: checkoutID))
  }

  static func checkoutStorageKey(
    projectID: String,
    checkoutID: String
  ) -> String {
    "\(projectID)::\(checkoutID)"
  }
}

struct SidebarSessionListContent: View, Equatable {
  nonisolated(unsafe) let renderState: SidebarSessionListRenderState
  let selection: Binding<String?>
  let selectSession: (String?) -> Void
  let toggleBookmark: (String, String) -> Void
  let setProjectCollapsed: (String, Bool) -> Void
  let setCheckoutCollapsed: (String, Bool) -> Void

  var body: some View {
    List(selection: selection) {
      sidebarRows
    }
  }

  @ViewBuilder
  private var sidebarRows: some View {
    switch renderState.emptyState {
    case .noSessions:
      SidebarEmptyState(
        title: "No sessions indexed yet",
        systemImage: "tray",
        message: "Start the daemon or refresh after launching a harness session."
      )
    case .noMatches:
      SidebarEmptyState(
        title: "No sessions match",
        systemImage: "magnifyingglass",
        message: "Try a broader search or clear filters."
      )
    case .sessionsAvailable:
      if renderState.usesFlatSearchResults {
        flatSearchResults
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)
      } else if let firstGroup = renderState.projectionGroups.first {
        projectSection(for: firstGroup)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
          .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)

        ForEach(Array(renderState.projectionGroups.dropFirst())) { group in
          projectSection(for: group)
        }
      }
    }
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.renderState == rhs.renderState
  }

  @ViewBuilder
  private var flatSearchResults: some View {
    ForEach(renderState.searchList.visibleSessions, id: \.sessionId) { session in
      sessionRow(session)
    }
  }

  private func projectSection(
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

  private func projectHeader(
    for group: HarnessMonitorStore.SessionGroup
  ) -> some View {
    Text(verbatim: group.project.name)
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
  private func checkoutDisclosureRow(
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

  private func checkoutHeader(
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
  private func sessionRow(_ session: SessionSummary) -> some View {
    let isSelectedForUITest =
      HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled
      && renderState.selectedSessionID == session.sessionId
    let row = SidebarSessionListLinkRow(
      session: session,
      isBookmarked: renderState.bookmarkedSessionIDs.contains(session.sessionId),
      lastActivityText: formatTimestamp(
        session.lastActivityAt,
        configuration: renderState.dateTimeConfiguration
      ),
      fontScale: renderState.fontScale
    )
    .equatable()

    let baseRow =
      row
      .tag(session.sessionId as String?)
      .onTapGesture {
        selectSession(session.sessionId)
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(sessionAccessibilityLabel(for: session))
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionRow(session.sessionId))
      .harnessUITestValue(
        isSelectedForUITest
          ? "selected, interactive=button, selectionChrome=translucent"
          : "interactive=button"
      )

    if renderState.isPersistenceAvailable {
      baseRow
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowFrame(session.sessionId)
        )
        .accessibilityFrameMarker(
          HarnessMonitorAccessibility.sessionRowSelectionFrame(session.sessionId),
          when: isSelectedForUITest
        )
        .accessibilityAction(named: "Toggle Bookmark") {
          toggleBookmark(session.sessionId, session.projectId)
        }
        .contextMenu {
          Button {
            toggleBookmark(session.sessionId, session.projectId)
          } label: {
            if renderState.bookmarkedSessionIDs.contains(session.sessionId) {
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
          when: isSelectedForUITest
        )
    }
  }

  private func projectExpansionBinding(
    for group: HarnessMonitorStore.SessionGroup
  ) -> Binding<Bool> {
    let projectID = group.project.projectId
    return Binding(
      get: { renderState.isProjectExpanded(projectID) },
      set: { isExpanded in
        setProjectCollapsed(projectID, !isExpanded)
      }
    )
  }

  private func checkoutExpansionBinding(
    for group: HarnessMonitorStore.CheckoutGroup,
    projectID: String
  ) -> Binding<Bool> {
    let checkoutKey = SidebarSessionListRenderState.checkoutStorageKey(
      projectID: projectID,
      checkoutID: group.checkoutId
    )
    return Binding(
      get: { renderState.isCheckoutExpanded(projectID: projectID, checkoutID: group.checkoutId) },
      set: { isExpanded in
        setCheckoutCollapsed(checkoutKey, !isExpanded)
      }
    )
  }

  private func scaledSidebarFont(_ font: Font) -> Font {
    HarnessMonitorTextSize.scaledFont(font, by: renderState.fontScale)
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
        Text(verbatim: group.title)
          .font(titleFont)
          .foregroundStyle(.secondary)
        Spacer()
        Text(verbatim: "\(group.sessionCount)")
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
