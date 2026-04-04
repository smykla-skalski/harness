import HarnessMonitorKit
import Observation
import SwiftUI

struct SidebarView: View {
  @Bindable var store: HarnessMonitorStore

  var body: some View {
    List {
      sessionSections
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top, spacing: 0) {
      sidebarHeader
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SidebarFooterAccessory(metrics: store.connectionMetrics)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessMonitorTheme.ink)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarRoot)
  }

  @ViewBuilder private var sessionSections: some View {
    if store.sessions.isEmpty {
      Section {
        VStack {
          ContentUnavailableView {
            Label("No sessions indexed yet", systemImage: "tray")
          } description: {
            Text("Start the daemon or refresh after launching a harness session.")
          }
        }
        .frame(maxWidth: .infinity)
        .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarEmptyStateFrame)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessMonitorTheme.sectionSpacing,
        leading: HarnessMonitorTheme.sectionSpacing,
        bottom: HarnessMonitorTheme.sectionSpacing,
        trailing: HarnessMonitorTheme.sectionSpacing
      ))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarEmptyState)
    } else if store.groupedSessions.isEmpty {
      Section {
        VStack {
          ContentUnavailableView {
            Label("No sessions match", systemImage: "magnifyingglass")
          } description: {
            Text("Try a broader search or clear filters.")
          }
        }
        .frame(maxWidth: .infinity)
        .accessibilityFrameMarker(HarnessMonitorAccessibility.sidebarEmptyStateFrame)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessMonitorTheme.sectionSpacing,
        leading: HarnessMonitorTheme.sectionSpacing,
        bottom: HarnessMonitorTheme.sectionSpacing,
        trailing: HarnessMonitorTheme.sectionSpacing
      ))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarEmptyState)
    } else if let firstGroup = store.groupedSessions.first {
      Group {
        sessionProjectRow(for: firstGroup)
          .listRowInsets(EdgeInsets(
            top: 0,
            leading: 0,
            bottom: 0,
            trailing: 0
          ))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)

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

      ForEach(Array(store.groupedSessions.dropFirst())) { group in
        Group {
          sessionProjectRow(for: group)
            .listRowInsets(EdgeInsets(
              top: HarnessMonitorTheme.sectionSpacing,
              leading: 0,
              bottom: 0,
              trailing: 0
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

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

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      DaemonStatusCard(
        connectionState: store.connectionState,
        isBusy: store.isBusy,
        isRefreshing: store.isRefreshing,
        projectCount: store.daemonStatus?.projectCount ?? store.projects.count,
        worktreeCount: store.daemonStatus?.worktreeCount ?? store.projects.reduce(0) { $0 + $1.worktrees.count },
        sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count,
        isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
        startDaemon: startDaemon,
        stopDaemon: stopDaemon,
        installLaunchAgent: installLaunchAgent
      )
      SidebarFilterContainer(store: store)
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .padding(.top, HarnessMonitorTheme.spacingXL)
    .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
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
    let isSelected = store.selectedSessionID == session.sessionId
    let baseRow = sessionBaseRow(session, isSelected: isSelected)

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
            if store.isBookmarked(sessionId: session.sessionId) {
              Label("Remove Bookmark", systemImage: "bookmark.slash")
            } else {
              Label("Bookmark", systemImage: "bookmark")
            }
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
    let sessionCard = sessionCardSurface(session, isSelected: isSelected)

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
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(
        sessionAccessibilityLabel(for: session)
      )
      .accessibilityValue(
        sessionAccessibilityValue(
          for: session,
          selectedSessionID: store.selectedSessionID
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
    .listRowInsets(EdgeInsets(
      top: HarnessMonitorTheme.itemSpacing,
      leading: 0,
      bottom: HarnessMonitorTheme.itemSpacing,
      trailing: 0
    ))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  private func sessionCardSurface(
    _ session: SessionSummary,
    isSelected: Bool
  ) -> some View {
    SidebarSessionRow(
      session: session,
      isBookmarked: store.isBookmarked(sessionId: session.sessionId),
      isSelected: isSelected
    )
    .padding(.horizontal, HarnessMonitorTheme.itemSpacing)
    .padding(.vertical, HarnessMonitorTheme.itemSpacing)
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
    .animation(.snappy(duration: 0.2), value: isSelected)
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

// TODO: Restore when TableViewListCore_Mac2 preview crash is fixed (macOS 26 SwiftUI bug)
// #Preview("Sidebar overflow") {
//   SidebarView(store: HarnessMonitorPreviewStoreFactory.makeStore(for: .sidebarOverflow))
//     .frame(width: 380, height: 900)
//     .modelContainer(HarnessMonitorPreviewStoreFactory.previewContainer)
// }
