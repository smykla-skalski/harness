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
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
          DaemonStatusCard(store: store)
          SidebarFilterSection(store: store)
        }
        .padding(.horizontal, HarnessTheme.sectionSpacing)
        .padding(.top, HarnessTheme.spacingXL)
        .padding(.bottom, HarnessTheme.sectionSpacing)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: 420)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarFiltersCard)
      .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ConnectionToolbarBadge(metrics: store.connectionMetrics)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HarnessTheme.itemSpacing)
        .padding(.horizontal, HarnessTheme.itemSpacing)
        .harnessRoundedRectGlass()
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
        ContentUnavailableView {
          Label("No sessions indexed yet", systemImage: "tray")
        } description: {
          Text("Start the daemon or refresh after launching a harness session.")
        }
      }
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
    } else if store.groupedSessions.isEmpty {
      Section {
        ContentUnavailableView.search(text: store.searchText)
      }
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
        SidebarSessionRow(session: session, store: store, isSelected: isSelected)
          .padding(.horizontal, rowContentPadding)
          .padding(.vertical, HarnessTheme.itemSpacing)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background {
            if isSelected {
              RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [HarnessTheme.accent.opacity(0.96), HarnessTheme.accent.opacity(0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                  )
                )
            }
          }
          .overlay {
            if isSelected {
              RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous)
                .strokeBorder(HarnessTheme.onContrast.opacity(0.18), lineWidth: 1)
            }
          }
          .contentShape(RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusLG, style: .continuous))
          .animation(.snappy(duration: 0.2), value: isSelected)
      }
      .harnessInteractiveCardButtonStyle(
        cornerRadius: HarnessTheme.cornerRadiusLG,
        tint: .clear
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
