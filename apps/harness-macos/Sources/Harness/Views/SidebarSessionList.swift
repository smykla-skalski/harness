import HarnessKit
import Observation
import SwiftUI

struct SidebarSessionList: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Bindable var store: HarnessStore

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
    VStack(alignment: .leading, spacing: 14) {
      filterSlice
      sessionList
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var filterSlice: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Search & Filters")
            .font(.system(.headline, design: .rounded, weight: .semibold))
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
          .harnessAccessoryButtonStyle(tint: HarnessTheme.accent(for: themeStyle))
          .controlSize(.small)
          .accessibilityIdentifier(HarnessAccessibility.sidebarClearFiltersButton)
        }
      }

      TextField("Search sessions, projects, leaders", text: $store.searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("harness.sidebar.search")
        .onSubmit {
          store.recordSearch(store.searchText)
        }

      if store.searchText.isEmpty {
        let recent = store.recentSearches
        if !recent.isEmpty {
          HStack(spacing: 6) {
            ForEach(recent.prefix(5), id: \.query) { search in
              Button {
                store.searchText = search.query
              } label: {
                Text(search.query)
                  .font(.caption)
                  .lineLimit(1)
              }
              .buttonStyle(.plain)
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background {
                HarnessGlassCapsuleBackground()
              }
            }
            Spacer()
            Button {
              store.clearSearchHistory()
            } label: {
              Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            .buttonStyle(.plain)
          }
        }
      }

      filterSection(title: "Status") {
        HarnessGlassContainer(spacing: 8) {
          HarnessWrapLayout(spacing: 6, lineSpacing: 6) {
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
      }

      filterSection(title: "Focus") {
        HarnessGlassContainer(spacing: 8) {
          HarnessWrapLayout(spacing: 6, lineSpacing: 6) {
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
    }
    .padding(14)
    .harnessInsetPanel(cornerRadius: 22, fillOpacity: 0.05, strokeOpacity: 0.50)
    .accessibilityElement(children: .contain)
    .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
  }

  private var sessionList: some View {
    SessionListContent(store: store)
  }
}

private struct SessionListContent: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Bindable var store: HarnessStore

  var body: some View {
    Group {
      if store.sessions.isEmpty {
        ContentUnavailableView {
          Label("No sessions indexed yet", systemImage: "tray")
        } description: {
          Text("Start the daemon or refresh after launching a harness session.")
        }
        .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
      } else if store.groupedSessions.isEmpty {
        ContentUnavailableView.search(text: store.searchText)
          .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
      } else {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(store.groupedSessions) { group in
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text(group.project.name)
                  .font(.system(.headline, design: .rounded, weight: .semibold))
                  .foregroundStyle(HarnessTheme.sidebarHeader(for: themeStyle))
                Spacer()
                Text("\(group.sessions.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(HarnessTheme.sidebarMuted(for: themeStyle))
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .harnessInsetPanel(cornerRadius: 16, fillOpacity: 0.04, strokeOpacity: 0.50)
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
                  VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                      Text(session.context)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                      Spacer(minLength: 12)
                      if store.isBookmarked(sessionId: session.sessionId) {
                        Image(systemName: "bookmark.fill")
                          .font(.caption2)
                          .foregroundStyle(HarnessTheme.accent(for: themeStyle))
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
                    HStack(spacing: 12) {
                      labelChip("\(session.metrics.activeAgentCount) active")
                      labelChip("\(session.metrics.inProgressTaskCount) moving")
                      labelChip(formatTimestamp(session.lastActivityAt))
                    }
                  }
                  .accessibilityElement(children: .combine)
                  .foregroundStyle(HarnessTheme.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(14)
                  .harnessSelectionOutline(
                    isSelected: store.selectedSessionID == session.sessionId,
                    cornerRadius: 18
                  )
                  .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .accessibilityIdentifier(HarnessAccessibility.sessionRow(session.sessionId))
                .accessibilityFrameMarker(
                  "\(HarnessAccessibility.sessionRow(session.sessionId)).frame"
                )
                .accessibilityValue(
                  sessionAccessibilityValue(for: session)
                )
                .harnessInteractiveCardButtonStyle(
                  tint: store.selectedSessionID == session.sessionId
                    ? HarnessTheme.surfaceHover(for: themeStyle)
                    : nil
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
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)
      }
    }
  }

  private func sessionAccessibilityValue(
    for session: SessionSummary
  ) -> String {
    let card = harnessInteractiveCardAccessibilityValue(for: themeStyle)
    let selected = store.selectedSessionID == session.sessionId
    if selected {
      return "selected, interactive=\(card)"
    }
    return "interactive=\(card)"
  }

  fileprivate func labelChip(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        HarnessGlassCapsuleBackground()
      }
  }
}

extension SidebarSessionList {
  fileprivate func filterSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
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
    Button(title, action: action)
      .font(.system(.callout, design: .rounded, weight: .semibold))
      .buttonBorderShape(.roundedRectangle(radius: 12))
      .harnessFilterChipButtonStyle(isSelected: isSelected)
      .controlSize(HarnessControlMetrics.compactControlSize)
      .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityIdentifier(identifier)
      .accessibilityFrameMarker("\(identifier).frame")
      .accessibilityValue(isSelected ? "selected" : "not selected")
  }

}
