import HarnessKit
import Observation
import SwiftData
import SwiftUI

struct SidebarFilterSection: View {
  let filteredSessionCount: Int
  let totalSessionCount: Int
  let searchText: String
  @Binding var draftSearchText: String
  let sessionFilter: HarnessStore.SessionFilter
  let sessionFocusFilter: SessionFocusFilter
  @Binding var sessionSortOrder: SessionSortOrder
  let isPersistenceAvailable: Bool
  let recentSearchQueries: [String]
  let resetFilters: () -> Void
  let submitSearch: () -> Void
  let setSessionFilter: (HarnessStore.SessionFilter) -> Void
  let setSessionFocusFilter: (SessionFocusFilter) -> Void
  let applyRecentSearch: (String) -> Void
  let clearSearchHistory: () -> Void

  private var activeFilterSummary: String {
    let isAnyFilterActive =
      !searchText.isEmpty
      || sessionFilter != .active
      || sessionFocusFilter != .all
    if isAnyFilterActive {
      return "\(filteredSessionCount) visible of \(totalSessionCount)"
    }
    return "\(totalSessionCount) indexed"
  }

  private var isFiltered: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || sessionFilter != .active
      || sessionFocusFilter != .all
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Search & Filters")
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text(activeFilterSummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        Spacer()
        if isFiltered {
          Button("Clear") {
            resetFilters()
          }
          .scaledFont(.caption.bold())
          .harnessAccessoryButtonStyle()
          .controlSize(.small)
          .accessibilityIdentifier(HarnessAccessibility.sidebarClearFiltersButton)
        }
      }

      SidebarSearchField(
        searchText: $draftSearchText,
        submitSearch: submitSearch
      )

      if searchText.isEmpty, isPersistenceAvailable {
        RecentSearchChipsSection(
          recentSearchQueries: recentSearchQueries,
          applyRecentSearch: applyRecentSearch,
          clearSearchHistory: clearSearchHistory
        )
      }

      filterSection(title: "Status") {
        HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
          HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
            ForEach(HarnessStore.SessionFilter.allCases) { filter in
              filterChip(
                title: filter.title,
                isSelected: sessionFilter == filter,
                identifier: HarnessAccessibility.sessionFilterButton(filter.rawValue)
              ) {
                setSessionFilter(filter)
              }
            }
          }
        }
      }

      filterSection(title: "Sort") {
        Picker("Sort", selection: $sessionSortOrder) {
          ForEach(SessionSortOrder.allCases) { order in
            Text(order.title).tag(order)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
      }

      filterSection(title: "Focus") {
        HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
          HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
            ForEach(SessionFocusFilter.allCases) { filter in
              filterChip(
                title: filter.title,
                isSelected: sessionFocusFilter == filter,
                identifier: HarnessAccessibility.sidebarFocusChip(filter.rawValue)
              ) {
                setSessionFocusFilter(filter)
              }
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
  }
}

private struct RecentSearchChipsSection: View {
  let recentSearchQueries: [String]
  let applyRecentSearch: (String) -> Void
  let clearSearchHistory: () -> Void

  var body: some View {
    if !recentSearchQueries.isEmpty {
      HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
        HStack(spacing: HarnessTheme.itemSpacing) {
          ForEach(recentSearchQueries, id: \.self) { query in
            Button(query) {
              applyRecentSearch(query)
            }
            .scaledFont(.caption)
            .lineLimit(1)
            .harnessAccessoryButtonStyle()
            .controlSize(.small)
          }
          Spacer()
          Button {
            clearSearchHistory()
          } label: {
            Image(systemName: "xmark.circle")
              .scaledFont(.caption2)
              .foregroundStyle(HarnessTheme.secondaryInk)
              .frame(minWidth: 24, minHeight: 24)
              .contentShape(Rectangle())
          }
          .harnessAccessoryButtonStyle()
          .controlSize(.small)
          .accessibilityIdentifier(HarnessAccessibility.sidebarClearSearchHistoryButton)
          .accessibilityLabel("Clear search history")
        }
      }
    }
  }
}

private struct SidebarSearchField: View {
  @Binding var searchText: String
  let submitSearch: () -> Void

  var body: some View {
    TextField("Search sessions, projects, leaders", text: $searchText)
      .textFieldStyle(.roundedBorder)
      .accessibilityIdentifier("harness.sidebar.search")
      .onSubmit(submitSearch)
  }
}

extension SidebarFilterSection {
  fileprivate func filterSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.bold))
        .tracking(HarnessTheme.uppercaseTracking)
        .foregroundStyle(HarnessTheme.secondaryInk)
      content()
    }
  }

  fileprivate func filterChip(
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
        .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
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

// MARK: - Accessibility helpers used by SidebarView

func sessionAccessibilityLabel(for session: SessionSummary) -> String {
  "\(session.context), \(session.projectName), \(session.status.title), \(session.sessionId)"
}

func sessionAccessibilityValue(
  for session: SessionSummary,
  selectedSessionID: String?
) -> String {
  let interactionStyle = "button"
  let selected = selectedSessionID == session.sessionId
  if selected {
    return "selected, interactive=\(interactionStyle), selectionChrome=translucent"
  }
  return "interactive=\(interactionStyle)"
}
