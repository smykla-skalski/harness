import HarnessKit
import Observation
import SwiftUI

struct SidebarView: View {
  @Bindable var store: HarnessStore

  var body: some View {
    List {
      sessionSections
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top, spacing: 0) {
      sidebarHeader
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ConnectionToolbarBadge(metrics: store.connectionMetrics)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HarnessTheme.itemSpacing)
        .padding(.horizontal, HarnessTheme.itemSpacing)
        .harnessFloatingControlGlass(
          cornerRadius: HarnessTheme.cornerRadiusMD,
          tint: HarnessTheme.ink
        )
        .padding(HarnessTheme.itemSpacing)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
    .accessibilityFrameMarker(HarnessAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarRoot)
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
        .accessibilityFrameMarker(HarnessAccessibility.sidebarEmptyStateFrame)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessTheme.sectionSpacing,
        leading: HarnessTheme.sectionSpacing,
        bottom: HarnessTheme.sectionSpacing,
        trailing: HarnessTheme.sectionSpacing
      ))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
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
        .accessibilityFrameMarker(HarnessAccessibility.sidebarEmptyStateFrame)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessTheme.sectionSpacing,
        leading: HarnessTheme.sectionSpacing,
        bottom: HarnessTheme.sectionSpacing,
        trailing: HarnessTheme.sectionSpacing
      ))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
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

        ForEach(firstGroup.sessions) { session in
          sessionRow(session)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarSessionList)
      .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)

      ForEach(Array(store.groupedSessions.dropFirst())) { group in
        Group {
          sessionProjectRow(for: group)
            .listRowInsets(EdgeInsets(
              top: HarnessTheme.sectionSpacing,
              leading: 0,
              bottom: 0,
              trailing: 0
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          ForEach(group.sessions) { session in
            sessionRow(session)
          }
        }
      }
    }
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      DaemonStatusCard(
        connectionState: store.connectionState,
        isBusy: store.isBusy,
        isRefreshing: store.isRefreshing,
        projectCount: store.daemonStatus?.projectCount ?? store.projects.count,
        sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count,
        isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
        startDaemon: startDaemon,
        stopDaemon: stopDaemon,
        installLaunchAgent: installLaunchAgent
      )
      SidebarFilterContainer(store: store)
    }
    .padding(.horizontal, HarnessTheme.sectionSpacing)
    .padding(.top, HarnessTheme.spacingXL)
    .padding(.bottom, HarnessTheme.sectionSpacing)
  }

  private func sessionProjectRow(for group: HarnessStore.SessionGroup) -> some View {
    HStack {
      Text(group.project.name)
        .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessTheme.ink)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Text("\(group.sessions.count)")
        .scaledFont(.caption.monospacedDigit())
        .foregroundStyle(HarnessTheme.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier(
      HarnessAccessibility.projectHeader(group.project.projectId)
    )
    .accessibilityFrameMarker(
      HarnessAccessibility.projectHeaderFrame(group.project.projectId)
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
        cornerRadius: HarnessTheme.cornerRadiusLG,
        tint: HarnessTheme.accent
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
        HarnessAccessibility.sessionRow(session.sessionId)
      )

      if HarnessUITestEnvironment.isEnabled {
        sessionCard
          .frame(maxWidth: .infinity, alignment: .leading)
          .opacity(0.001)
          .allowsHitTesting(false)
          .accessibilityElement(children: .ignore)
          .accessibilityIdentifier(HarnessAccessibility.sessionRowFrame(session.sessionId))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .listRowInsets(EdgeInsets(
      top: HarnessTheme.itemSpacing,
      leading: 0,
      bottom: HarnessTheme.itemSpacing,
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
    .padding(.horizontal, HarnessTheme.itemSpacing)
    .padding(.vertical, HarnessTheme.itemSpacing)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous)
          .fill(HarnessTheme.accent.opacity(0.16))
      }
    }
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous)
          .strokeBorder(HarnessTheme.accent.opacity(0.24), lineWidth: 1)
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous))
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

#Preview("Sidebar overflow") {
  SidebarView(store: HarnessPreviewStoreFactory.makeStore(for: .sidebarOverflow))
    .frame(width: 380, height: 900)
}
