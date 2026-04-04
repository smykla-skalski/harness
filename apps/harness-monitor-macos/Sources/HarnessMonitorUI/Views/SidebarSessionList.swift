import HarnessMonitorKit
import Observation
import SwiftData
import SwiftUI

struct SidebarFilterSection: View {
  let filteredSessionCount: Int
  let totalSessionCount: Int
  let searchText: String
  @Binding var draftSearchText: String
  let sessionFilter: HarnessMonitorStore.SessionFilter
  let sessionFocusFilter: SessionFocusFilter
  @Binding var sessionSortOrder: SessionSortOrder
  let isPersistenceAvailable: Bool
  let recentSearchQueries: [String]
  let resetFilters: () -> Void
  let submitSearch: () -> Void
  let setSessionFilter: (HarnessMonitorStore.SessionFilter) -> Void
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Search & Filters")
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text(activeFilterSummary)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer()
        if isFiltered {
          Button("Clear") {
            resetFilters()
          }
          .scaledFont(.caption.bold())
          .harnessAccessoryButtonStyle()
          .controlSize(.small)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
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
        SidebarSegmentedPicker(
          title: "Status",
          options: HarnessMonitorStore.SessionFilter.allCases,
          selection: Binding(
            get: { sessionFilter },
            set: { newValue in
              withAnimation(.spring(duration: 0.2)) {
                setSessionFilter(newValue)
              }
            }
          ),
          optionTitle: \.title,
          optionIdentifier: { HarnessMonitorAccessibility.sessionFilterButton($0.rawValue) }
        )
      }
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.sessionFilterGroup,
        label: "status=\(sessionFilter.rawValue)"
      )

      filterSection(title: "Sort") {
        SidebarSegmentedPicker(
          title: "Sort",
          options: SessionSortOrder.allCases,
          selection: $sessionSortOrder,
          optionTitle: \.title,
          optionIdentifier: { HarnessMonitorAccessibility.sidebarSortSegment($0.rawValue) }
        )
      }

      filterSection(title: "Focus") {
        SidebarSegmentedPicker(
          title: "Focus",
          options: SessionFocusFilter.allCases,
          selection: Binding(
            get: { sessionFocusFilter },
            set: { newValue in
              withAnimation(.spring(duration: 0.2)) {
                setSessionFocusFilter(newValue)
              }
            }
          ),
          optionTitle: \.title,
          optionIdentifier: { HarnessMonitorAccessibility.sidebarFocusChip($0.rawValue) }
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sidebarFiltersCard).frame")
  }
}

private struct RecentSearchChipsSection: View {
  let recentSearchQueries: [String]
  let applyRecentSearch: (String) -> Void
  let clearSearchHistory: () -> Void

  var body: some View {
    if !recentSearchQueries.isEmpty {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HStack(spacing: HarnessMonitorTheme.itemSpacing) {
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
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .frame(minWidth: 24, minHeight: 24)
              .contentShape(Rectangle())
          }
          .harnessAccessoryButtonStyle()
          .controlSize(.small)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearSearchHistoryButton)
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
      .harnessNativeFormControl()
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.bold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
  }

}

private struct SidebarSegmentedPicker<Option: Hashable & Identifiable>: View {
  let title: String
  let options: [Option]
  @Binding var selection: Option
  let optionTitle: (Option) -> String
  let optionIdentifier: (Option) -> String

  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(options) { option in
        let title = optionTitle(option)
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .accessibilityLabel(title)
          .accessibilityValue(selection == option ? "selected" : "not selected")
          .accessibilityAddTraits(selection == option ? .isSelected : [])
          .accessibilityIdentifier(optionIdentifier(option))
          .tag(option)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .harnessNativeFormControl()
  }
}

// MARK: - Accessibility helpers used by SidebarView

func sessionAccessibilityLabel(for session: SessionSummary) -> String {
  "\(session.context), \(session.projectName), \(session.checkoutDisplayName), \(session.status.title), \(session.sessionId)"
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
