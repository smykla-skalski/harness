import HarnessKit
import Observation
import SwiftUI

struct SidebarView: View {
  let store: HarnessStore
  @State private var localSelection: String?

  var body: some View {
    List(selection: $localSelection) {
      Section {
        DaemonStatusCard(store: store)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessTheme.spacingXL,
        leading: HarnessTheme.sectionSpacing,
        bottom: 0,
        trailing: HarnessTheme.sectionSpacing
      ))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)

      Section {
        SidebarFilterSection(store: store)
      }
      .listRowInsets(EdgeInsets(
        top: HarnessTheme.sectionSpacing,
        leading: HarnessTheme.sectionSpacing,
        bottom: HarnessTheme.sectionSpacing,
        trailing: HarnessTheme.sectionSpacing
      ))
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)

      sessionSections
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      ConnectionToolbarBadge(metrics: store.connectionMetrics)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HarnessTheme.itemSpacing)
        .padding(.horizontal, HarnessTheme.itemSpacing)
        .harnessRoundedRectGlass()
        .padding(HarnessTheme.itemSpacing)
    }
    .animation(.snappy(duration: 0.24), value: store.groupedSessions)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .foregroundStyle(HarnessTheme.ink)
    .accessibilityFrameMarker(HarnessAccessibility.sidebarShellFrame)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarRoot)
    .onAppear {
      localSelection = store.selectedSessionID
    }
    .onChange(of: store.selectedSessionID) { _, newID in
      if localSelection != newID { localSelection = newID }
    }
    .onChange(of: localSelection) { _, newID in
      guard newID != store.selectedSessionID else { return }
      Task { await store.selectSession(newID) }
    }
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
          ForEach(group.sessions) { session in
            SidebarSessionRow(session: session, store: store)
              .tag(session.sessionId)
              .listRowInsets(EdgeInsets(
                top: HarnessTheme.itemSpacing,
                leading: HarnessTheme.cardPadding,
                bottom: HarnessTheme.itemSpacing,
                trailing: HarnessTheme.cardPadding
              ))
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
              .accessibilityAction(named: "Toggle Bookmark") {
                store.toggleBookmark(
                  sessionId: session.sessionId,
                  projectId: session.projectId
                )
              }
              .accessibilityIdentifier(
                HarnessAccessibility.sessionRow(session.sessionId)
              )
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
          }
        } header: {
          HStack {
            Text(group.project.name)
              .font(.system(.headline, design: .rounded, weight: .semibold))
              .foregroundStyle(HarnessTheme.ink)
              .accessibilityAddTraits(.isHeader)
            Spacer()
            Text("\(group.sessions.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          .accessibilityIdentifier(
            HarnessAccessibility.projectHeader(group.project.projectId)
          )
          .accessibilityFrameMarker(
            HarnessAccessibility.projectHeaderFrame(group.project.projectId)
          )
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessAccessibility.sidebarSessionList)
      .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)
    }
  }
}
