import HarnessKit
import SwiftUI

struct SidebarView: View {
  let store: HarnessStore

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
          ContentUnavailableView.search(text: store.searchText)
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
    } else {
      ForEach(store.groupedSessions) { group in
        Section {
          sessionProjectRow(for: group)
            .listRowInsets(EdgeInsets(
              top: HarnessTheme.sectionSpacing,
              leading: HarnessTheme.sectionSpacing,
              bottom: 0,
              trailing: HarnessTheme.sectionSpacing
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

          ForEach(group.sessions) { session in
            sessionRow(session)
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarSessionList)
      .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)
    }
  }

  private var sidebarHeader: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      DaemonStatusCard(store: store)
      SidebarFilterSection(store: store)
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
    let rowContentPadding = HarnessTheme.spacingLG
    let rowOuterInset = HarnessTheme.sectionSpacing
    let baseRow =
      Button {
        Task { await store.selectSession(session.sessionId) }
      } label: {
        SidebarSessionRow(
          session: session,
          isBookmarked: store.isBookmarked(sessionId: session.sessionId),
          isSelected: isSelected
        )
          .padding(.horizontal, rowContentPadding)
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
      .harnessSidebarRowButtonStyle(
        cornerRadius: HarnessTheme.cornerRadiusLG,
        tint: HarnessTheme.accent
      )
      .listRowInsets(EdgeInsets(
        top: HarnessTheme.itemSpacing,
        leading: rowOuterInset,
        bottom: HarnessTheme.itemSpacing,
        trailing: rowOuterInset
      ))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
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
}

#Preview("Sidebar overflow") {
  SidebarView(store: HarnessPreviewStoreFactory.makeStore(for: .sidebarOverflow))
    .frame(width: 380, height: 900)
}
