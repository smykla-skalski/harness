import HarnessKit
import Observation
import SwiftUI

struct SidebarFilterSection: View {
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
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
            }
            .harnessAccessoryButtonStyle()
            .controlSize(.small)
            .accessibilityLabel("Clear search history")
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

      filterSection(title: "Sort") {
        Picker("Sort", selection: $store.sessionSortOrder) {
          ForEach(SessionSortOrder.allCases) { order in
            Text(order.title).tag(order)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
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
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
  }
}

extension SidebarFilterSection {
  fileprivate func filterSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
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

// MARK: - Accessibility helpers used by SidebarView

func sessionAccessibilityLabel(for session: SessionSummary) -> String {
  "\(session.context), \(session.projectName), \(session.status.title), \(session.sessionId)"
}

func sessionAccessibilityValue(
  for session: SessionSummary,
  selectedSessionID: String?
) -> String {
  let interactionStyle = "list"
  let selected = selectedSessionID == session.sessionId
  if selected {
    return "selected, interactive=\(interactionStyle)"
  }
  return "interactive=\(interactionStyle)"
}
