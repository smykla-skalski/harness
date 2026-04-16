import HarnessMonitorKit
import SwiftUI

@MainActor
struct SidebarSessionListRenderState {
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let projectionGroups: [HarnessMonitorStore.SessionGroup]
  let searchPresentation: HarnessMonitorStore.SessionSearchPresentationState
  let searchVisibleSessionIDs: [String]
  let selectedSessionIDForAccessibilityMarkers: String?
  let bookmarkedSessionIDs: Set<String>
  let isPersistenceAvailable: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  let fontScale: CGFloat
  let collapsedCheckoutKeys: Set<String>

  var emptyState: HarnessMonitorStore.SidebarEmptyState {
    searchPresentation.emptyState
  }

  var usesFlatSearchResults: Bool {
    searchPresentation.isSearchActive
  }

  var groupedProjectCount: Int {
    projectionGroups.count
  }

  var groupedWorktreeCount: Int {
    projectionGroups.reduce(into: 0) { partialResult, group in
      partialResult += group.checkoutGroups.count
    }
  }

  var groupedSessionCount: Int {
    projectionGroups.reduce(into: 0) { partialResult, group in
      partialResult += group.sessionIDs.count
    }
  }

  var groupedStateAccessibilityLabel: String {
    "projects=\(groupedProjectCount), worktrees=\(groupedWorktreeCount), sessions=\(groupedSessionCount)"
  }

  func sessionSummary(for sessionID: String) -> SessionSummary? {
    sessionCatalog.sessionSummary(for: sessionID)
  }

  func isCheckoutExpanded(
    projectID: String,
    checkoutID: String
  ) -> Bool {
    !collapsedCheckoutKeys.contains(
      Self.checkoutStorageKey(projectID: projectID, checkoutID: checkoutID))
  }

  static func checkoutStorageKey(
    projectID: String,
    checkoutID: String
  ) -> String {
    "\(projectID)::\(checkoutID)"
  }
}

@MainActor
struct SidebarSessionListContent: View {
  let store: HarnessMonitorStore
  let renderState: SidebarSessionListRenderState
  let toggleBookmark: (String, String) -> Void
  let setCheckoutCollapsed: (String, Bool) -> Void

  var body: some View {
    sidebarRows
  }

  @ViewBuilder private var sidebarRows: some View {
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

  @ViewBuilder private var flatSearchResults: some View {
    ForEach(renderState.searchVisibleSessionIDs, id: \.self) { sessionID in
      if let session = renderState.sessionSummary(for: sessionID) {
        sessionRow(session)
      }
    }
  }

  private func projectSection(
    for group: HarnessMonitorStore.SessionGroup
  ) -> some View {
    Section {
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
    HStack(spacing: 0) {
      Text(verbatim: group.project.name)
        .font(scaledSidebarFont(.system(.headline, design: .rounded, weight: .semibold)))
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .contentShape(Rectangle())
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
      ForEach(group.sessionIDs, id: \.self) { sessionID in
        if let session = renderState.sessionSummary(for: sessionID) {
          sessionRow(session)
        }
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
    let presentation = store.sessionSummaryPresentation(for: session)
    let isSelectedForUITest =
      HarnessMonitorUITestEnvironment.selectionMarkersEnabled
      && renderState.selectedSessionIDForAccessibilityMarkers == session.sessionId
    let row = sessionRowContent(session, presentation: presentation)

    let baseRow =
      row
      .tag(session.sessionId as String?)
      .contentShape(Rectangle())
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(
        sessionAccessibilityLabel(for: session, presentation: presentation)
      )
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

  @ViewBuilder
  private func sessionRowContent(
    _ session: SessionSummary,
    presentation: HarnessMonitorStore.SessionSummaryPresentation
  ) -> some View {
    let row = SidebarSessionListLinkRow(
      session: session,
      presentation: presentation,
      isBookmarked: renderState.bookmarkedSessionIDs.contains(session.sessionId),
      lastActivityText: formatTimestamp(
        session.lastActivityAt,
        configuration: renderState.dateTimeConfiguration
      ),
      fontScale: renderState.fontScale
    )

    if HarnessMonitorUITestEnvironment.isPerfScenarioActive {
      row.equatable()
    } else {
      row
    }
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

extension View {
  @ViewBuilder
  fileprivate func accessibilityFrameMarker(_ identifier: String, when condition: Bool) -> some View
  {
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
    .harnessSidebarDisclosureButtonStyle()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(group.title)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.worktreeHeader(group.checkoutId)
    )
    .accessibilityFrameMarker(
      HarnessMonitorAccessibility.worktreeHeaderFrame(group.checkoutId)
    )
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.worktreeHeaderGlyph(group.checkoutId),
      label: leadingIconName
    )
  }

  private var leadingIconName: String {
    isExpanded ? "chevron.down" : "chevron.right"
  }

  private static let leadingIconWidth: CGFloat = HarnessMonitorTheme.spacingLG
}
