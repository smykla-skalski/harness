import HarnessMonitorKit
import Observation
import SwiftUI

struct SidebarView: View {
  let store: HarnessMonitorStore
  let sessionIndex: HarnessMonitorStore.SessionIndexSlice
  let sidebarUI: HarnessMonitorStore.SidebarUISlice

  var body: some View {
    ScrollView {
      SidebarSessionListSection(
        store: store,
        sessionIndex: sessionIndex,
        sidebarUI: sidebarUI
      )
      .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
    .safeAreaInset(edge: .top, spacing: 0) {
      SidebarHeaderSection(
        store: store,
        sessionIndex: sessionIndex,
        sidebarUI: sidebarUI
      )
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooterSection(sidebarUI: sidebarUI)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessMonitorTheme.ink)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
  }
}

private struct SidebarHeaderSection: View {
  let store: HarnessMonitorStore
  @Bindable var sessionIndex: HarnessMonitorStore.SessionIndexSlice
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice

  init(
    store: HarnessMonitorStore,
    sessionIndex: HarnessMonitorStore.SessionIndexSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice
  ) {
    self.store = store
    self.sessionIndex = sessionIndex
    self.sidebarUI = sidebarUI
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      DaemonStatusCard(
        connectionState: sidebarUI.connectionState,
        isBusy: sidebarUI.isBusy,
        isRefreshing: sidebarUI.isRefreshing,
        isLaunchAgentInstalled: sidebarUI.isLaunchAgentInstalled,
        startDaemon: startDaemon,
        stopDaemon: stopDaemon,
        installLaunchAgent: installLaunchAgent
      )
      SidebarFilterContainer(
        store: store,
        sessionIndex: sessionIndex,
        sidebarUI: sidebarUI
      )
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .padding(.top, HarnessMonitorTheme.spacingXL)
    .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
  }

  private func startDaemon() async {
    await store.startDaemon()
  }

  private func stopDaemon() async {
    await store.stopDaemon()
  }

  private func installLaunchAgent() async {
    await store.installLaunchAgent()
  }
}

private struct SidebarFooterSection: View {
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice

  init(sidebarUI: HarnessMonitorStore.SidebarUISlice) {
    self.sidebarUI = sidebarUI
  }

  var body: some View {
    SidebarFooterAccessory(metrics: sidebarUI.connectionMetrics)
  }
}

private struct SidebarSessionListSection: View {
  let store: HarnessMonitorStore
  @Bindable var sessionIndex: HarnessMonitorStore.SessionIndexSlice
  @Bindable var sidebarUI: HarnessMonitorStore.SidebarUISlice

  init(
    store: HarnessMonitorStore,
    sessionIndex: HarnessMonitorStore.SessionIndexSlice,
    sidebarUI: HarnessMonitorStore.SidebarUISlice
  ) {
    self.store = store
    self.sessionIndex = sessionIndex
    self.sidebarUI = sidebarUI
  }

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      sessionSections
    }
  }

  @ViewBuilder private var sessionSections: some View {
    switch sidebarUI.emptyState {
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
      if let firstGroup = sessionIndex.groupedSessions.first {
        Group {
          sessionProjectRow(for: firstGroup)

          ForEach(firstGroup.checkoutGroups) { checkoutGroup in
            sessionCheckoutRow(for: checkoutGroup)
            ForEach(checkoutGroup.sessions) { session in
              sessionRow(session)
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSessionList)
        .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarSessionListContent)

        ForEach(Array(sessionIndex.groupedSessions.dropFirst())) { group in
          Group {
            sessionProjectRow(for: group)
              .padding(.top, HarnessMonitorTheme.sectionSpacing)

            ForEach(group.checkoutGroups) { checkoutGroup in
              sessionCheckoutRow(for: checkoutGroup)
              ForEach(checkoutGroup.sessions) { session in
                sessionRow(session)
              }
            }
          }
        }
      }
    }
  }

  private func sessionProjectRow(for group: HarnessMonitorStore.SessionGroup) -> some View {
    HStack {
      Text(group.project.name)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Text("\(group.sessions.count)")
        .scaledFont(.caption.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.projectHeader(group.project.projectId)
    )
    .accessibilityFrameMarker(
      HarnessMonitorAccessibility.projectHeaderFrame(group.project.projectId)
    )
  }

  private func sessionCheckoutRow(
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
    .padding(.top, HarnessMonitorTheme.itemSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.worktreeHeader(group.checkoutId)
    )
  }

  @ViewBuilder
  private func sessionRow(_ session: SessionSummary) -> some View {
    let isSelected = sidebarUI.selectedSessionID == session.sessionId
    let baseRow = sessionBaseRow(session, isSelected: isSelected)

    if sidebarUI.isPersistenceAvailable {
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
    }
  }

  private func sessionBaseRow(
    _ session: SessionSummary,
    isSelected: Bool
  ) -> some View {
    let sessionCard = SidebarSessionCardSurface(
      session: session,
      isBookmarked: sidebarUI.bookmarkedSessionIds.contains(session.sessionId),
      isSelected: isSelected
    )

    return ZStack(alignment: .leading) {
      Button {
        Task { await store.selectSession(session.sessionId) }
      } label: {
        sessionCard
      }
      .harnessSidebarRowButtonStyle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
        tint: HarnessMonitorTheme.accent
      )
      .accessibilityLabel(
        sessionAccessibilityLabel(for: session)
      )
      .accessibilityValue(
        sessionAccessibilityValue(
          for: session,
          selectedSessionID: sidebarUI.selectedSessionID
        )
      )
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.sessionRow(session.sessionId)
      )

      if HarnessMonitorUITestEnvironment.isEnabled {
        sessionCard
          .frame(maxWidth: .infinity, alignment: .leading)
          .opacity(0.001)
          .allowsHitTesting(false)
          .accessibilityElement(children: .ignore)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sessionRowFrame(session.sessionId))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }
}

private struct SidebarEmptyState: View {
  let title: String
  let systemImage: String
  let message: String

  var body: some View {
    VStack {
      ContentUnavailableView {
        Label(title, systemImage: systemImage)
      } description: {
        Text(message)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(HarnessMonitorTheme.sectionSpacing)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarEmptyStateFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarEmptyState)
  }
}

private struct SidebarSessionCardSurface: View {
  let session: SessionSummary
  let isBookmarked: Bool
  let isSelected: Bool
  @State private var isHovered = false

  var body: some View {
    SidebarSessionRow(
      session: session,
      isBookmarked: isBookmarked,
      isSelected: isSelected,
      isHovered: isHovered
    )
    .padding(HarnessMonitorTheme.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
          .fill(HarnessMonitorTheme.accent.opacity(0.16))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
          .strokeBorder(HarnessMonitorTheme.accent.opacity(0.24), lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous))
    .onHover { isHovered = $0 }
    .animation(.snappy(duration: 0.2), value: isSelected)
  }
}

// TODO: Restore when TableViewListCore_Mac2 preview crash is fixed (macOS 26 SwiftUI bug)
// #Preview("Sidebar overflow") {
//   SidebarView(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .sidebarOverflow))
//     .frame(width: 380, height: 900)
//     .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
// }
