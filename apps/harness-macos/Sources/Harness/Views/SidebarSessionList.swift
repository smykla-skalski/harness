import HarnessKit
import Observation
import SwiftUI

struct SidebarSessionList: View {
  @Bindable var store: HarnessStore
  @State private var localSearchText = ""

  private var activeFilterSummary: String {
    let visibleCount = store.filteredSessionCount
    let totalCount = store.sessions.count
    let isAnyFilterActive =
      !store.searchText.isEmpty
      || store.sessionFilter != .active
      || store.sessionFocusFilter != .all
    if isAnyFilterActive {
      return "\(visibleCount) visible of \(totalCount)"
    }
    return "\(totalCount) indexed"
  }

  private var isFiltered: Bool {
    !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.sessionFilter != .active
      || store.sessionFocusFilter != .all
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      filterSlice
      sessionList
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var filterSlice: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Search & Filters")
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text(activeFilterSummary)
            .font(.caption)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        Spacer()
        if isFiltered {
          Button("Clear") {
            store.resetFilters()
          }
          .font(.caption.bold())
          .harnessAccessoryButtonStyle()
          .controlSize(.small)
          .accessibilityIdentifier(HarnessAccessibility.sidebarClearFiltersButton)
        }
      }

      TextField("Search sessions, projects, leaders", text: $localSearchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("harness.sidebar.search")
        .onSubmit {
          store.recordSearch(store.searchText)
        }
        .task(id: localSearchText) {
          try? await Task.sleep(for: .milliseconds(300))
          guard !Task.isCancelled else { return }
          store.searchText = localSearchText
        }
        .onAppear { localSearchText = store.searchText }
        .onChange(of: store.searchText) { _, new in
          if localSearchText != new { localSearchText = new }
        }

      if store.searchText.isEmpty {
        let recent = store.recentSearches
        if !recent.isEmpty {
          HStack(spacing: HarnessTheme.itemSpacing) {
            ForEach(recent.prefix(5), id: \.query) { search in
              Button(search.query) {
                store.searchText = search.query
              }
              .font(.caption)
              .lineLimit(1)
              .harnessAccessoryButtonStyle()
              .controlSize(.small)
            }
            Spacer()
            Button {
              store.clearSearchHistory()
            } label: {
              Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            .harnessAccessoryButtonStyle()
            .controlSize(.small)
          }
        }
      }

      filterSection(title: "Status") {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          ForEach(HarnessStore.SessionFilter.allCases) { filter in
            filterChip(
              title: filter.title,
              isSelected: store.sessionFilter == filter,
              identifier: HarnessAccessibility.sessionFilterButton(filter.rawValue)
            ) {
              store.sessionFilter = filter
            }
          }
        }
      }

      filterSection(title: "Focus") {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          ForEach(SessionFocusFilter.allCases) { filter in
            filterChip(
              title: filter.title,
              isSelected: store.sessionFocusFilter == filter,
              identifier: HarnessAccessibility.sidebarFocusChip(filter.rawValue)
            ) {
              store.sessionFocusFilter = filter
            }
          }
        }
      }
    }
    .padding(HarnessTheme.cardPadding)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
  }

  private var sessionList: some View {
    SessionListContent(store: store)
  }
}

private struct SessionListContent: View {
  let store: HarnessStore

  var body: some View {
    Group {
      if store.sessions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ContentUnavailableView {
            Label("No sessions indexed yet", systemImage: "tray")
          } description: {
            Text("Start the daemon or refresh after launching a harness session.")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
      } else if store.groupedSessions.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ContentUnavailableView.search(text: store.searchText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
      } else {
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(store.groupedSessions) { group in
            VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
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

              ForEach(group.sessions) { session in
                Button {
                  Task {
                    await store.selectSession(session.sessionId)
                  }
                } label: {
                  VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
                    HStack(alignment: .top, spacing: HarnessTheme.itemSpacing) {
                      Text(session.context)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                      Spacer(minLength: 12)
                      if store.isBookmarked(sessionId: session.sessionId) {
                        Image(systemName: "bookmark.fill")
                          .font(.caption2)
                          .foregroundStyle(HarnessTheme.accent)
                          .accessibilityLabel("Bookmarked")
                      }
                      Circle()
                        .fill(statusColor(for: session.status))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    }
                    Text(session.sessionId)
                      .font(.caption.monospaced())
                      .foregroundStyle(HarnessTheme.secondaryInk)
                    HStack(spacing: HarnessTheme.sectionSpacing) {
                      labelChip("\(session.metrics.activeAgentCount) active")
                      labelChip("\(session.metrics.inProgressTaskCount) moving")
                      labelChip(formatTimestamp(session.lastActivityAt))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                  }
                  .foregroundStyle(HarnessTheme.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(HarnessTheme.cardPadding)
                  .harnessSelectionOutline(
                    isSelected: store.selectedSessionID == session.sessionId,
                    cornerRadius: HarnessTheme.cornerRadiusMD
                  )
                }
                .accessibilityLabel(
                  sessionAccessibilityLabel(for: session)
                )
                .accessibilityValue(
                  sessionAccessibilityValue(for: session)
                )
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Toggle Bookmark") {
                  store.toggleBookmark(
                    sessionId: session.sessionId,
                    projectId: session.projectId
                  )
                }
                .accessibilityIdentifier(HarnessAccessibility.sessionRow(session.sessionId))
                .harnessInteractiveCardButtonStyle()
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
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessAccessibility.sidebarSessionList)
        .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)
      }
    }
    .animation(.snappy(duration: 0.24), value: store.groupedSessions)
  }

  private func sessionAccessibilityValue(
    for session: SessionSummary
  ) -> String {
    let interactionStyle = "plain"
    let selected = store.selectedSessionID == session.sessionId
    if selected {
      return "selected, interactive=\(interactionStyle)"
    }
    return "interactive=\(interactionStyle)"
  }

  private func sessionAccessibilityLabel(
    for session: SessionSummary
  ) -> String {
    "\(session.context), \(session.projectName), \(session.sessionId)"
  }

  fileprivate func labelChip(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .harnessPillPadding()
      .harnessInfoPill()
  }
}

extension SidebarSessionList {
  fileprivate func filterSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      content()
    }
  }

  private func filterChip(
    title: String,
    isSelected: Bool,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      withAnimation(.spring(duration: 0.2)) {
        action()
      }
    } label: {
      Text(title)
        .font(.system(.callout, design: .rounded, weight: .semibold))
    }
    .buttonBorderShape(.roundedRectangle(radius: 12))
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
    .accessibilityFrameMarker("\(identifier).frame")
  }
}
