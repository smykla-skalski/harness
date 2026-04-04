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
  let isExpanded: Bool
  let resetFilters: () -> Void
  let toggleExpanded: () -> Void
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      SidebarFilterHeader(
        activeFilterSummary: activeFilterSummary,
        isFiltered: isFiltered,
        isExpanded: isExpanded,
        resetFilters: resetFilters,
        toggleExpanded: toggleExpanded
      )

      if isExpanded {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
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
          }

          SidebarFilterControlsBar(
            sessionFilter: Binding(
              get: { sessionFilter },
              set: { newValue in
                withAnimation(.spring(duration: 0.2)) {
                  setSessionFilter(newValue)
                }
              }
            ),
            sessionSortOrder: $sessionSortOrder,
            sessionFocusFilter: Binding(
              get: { sessionFocusFilter },
              set: { newValue in
                withAnimation(.spring(duration: 0.2)) {
                  setSessionFocusFilter(newValue)
                }
              }
            )
          )
        }
        .transition(FilterContentTransition())
      }
    }
    .animation(.spring(duration: 0.38, bounce: 0.18), value: isExpanded)
    .clipped()
    .sensoryFeedback(.selection, trigger: isExpanded)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .harnessFloatingControlGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: HarnessMonitorTheme.ink,
      prominence: .subdued
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.sidebarFiltersCard).frame")
  }
}

private struct SidebarFilterHeader: View {
  @ScaledMetric(relativeTo: .caption) private var trailingControlsMinHeight = 24

  let activeFilterSummary: String
  let isFiltered: Bool
  let isExpanded: Bool
  let resetFilters: () -> Void
  let toggleExpanded: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
      title
      Spacer(minLength: HarnessMonitorTheme.itemSpacing)
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.itemSpacing) {
        summary
        if isFiltered {
          clearButton
        }
      }
      .frame(minHeight: trailingControlsMinHeight, alignment: .trailing)
    }
  }

  private var title: some View {
    Button {
      toggleExpanded()
    } label: {
      HStack(spacing: 4) {
        Text("Search & Filters")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Image(systemName: "chevron.down")
          .scaledFont(.caption.weight(.semibold))
          .rotationEffect(isExpanded ? .zero : .degrees(-90))
          .animation(.spring(duration: 0.28, bounce: 0.2), value: isExpanded)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .buttonStyle(FilterToggleButtonStyle())
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel("Search & Filters")
    .accessibilityHint(isExpanded ? "Collapse filters" : "Expand filters")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarFiltersToggle)
  }

  private var summary: some View {
    Text(activeFilterSummary)
      .scaledFont(.caption.weight(.medium))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .multilineTextAlignment(.trailing)
  }

  private var clearButton: some View {
    Button("Clear") {
      resetFilters()
    }
    .scaledFont(.caption.bold())
    .harnessFlatActionButtonStyle()
    .controlSize(.small)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearFiltersButton)
  }

}

// Collapses content toward the header: scale from top + fade.
// Stays within the VStack layout frame — no overflow past card edges.
private struct FilterContentTransition: Transition {
  func body(content: Content, phase: TransitionPhase) -> some View {
    content
      .opacity(phase.isIdentity ? 1 : 0)
      .scaleEffect(x: 1, y: phase.isIdentity ? 1 : 0.88, anchor: .top)
  }
}

private struct FilterToggleButtonStyle: ButtonStyle {
  @State private var isHovered = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.vertical, 2)
      .padding(.horizontal, 4)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(
            configuration.isPressed
              ? HarnessMonitorTheme.ink.opacity(0.14)
              : isHovered
                ? HarnessMonitorTheme.ink.opacity(0.08)
                : Color.clear
          )
      }
      .scaleEffect(configuration.isPressed ? 0.96 : 1, anchor: .leading)
      .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.15), value: isHovered)
      .onHover { isHovered = $0 }
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

private struct SidebarFilterControlsBar: View {
  @Binding var sessionFilter: HarnessMonitorStore.SessionFilter
  @Binding var sessionSortOrder: SessionSortOrder
  @Binding var sessionFocusFilter: SessionFocusFilter

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      SidebarLabeledSegmentedField(
        title: "Status",
        options: HarnessMonitorStore.SessionFilter.allCases,
        selection: $sessionFilter,
        optionTitle: \.title,
        optionIdentifier: { HarnessMonitorAccessibility.sessionFilterButton($0.rawValue) }
      )
      .accessibilityTestProbe(
        HarnessMonitorAccessibility.sessionFilterGroup,
        label: "status=\(sessionFilter.rawValue)"
      )

      SidebarLabeledSegmentedField(
        title: "Sort",
        options: SessionSortOrder.allCases,
        selection: $sessionSortOrder,
        optionTitle: \.title,
        optionIdentifier: { HarnessMonitorAccessibility.sidebarSortSegment($0.rawValue) }
      )

      SidebarLabeledSegmentedField(
        title: "Focus",
        options: SessionFocusFilter.allCases,
        selection: $sessionFocusFilter,
        optionTitle: \.title,
        optionIdentifier: { HarnessMonitorAccessibility.sidebarFocusChip($0.rawValue) }
      )
    }
  }
}

private struct SidebarLabeledSegmentedField<Option: Hashable & Identifiable>: View {
  let title: String
  let options: [Option]
  @Binding var selection: Option
  let optionTitle: (Option) -> String
  let optionIdentifier: (Option) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.bold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      SidebarSegmentedPicker(
        title: title,
        options: options,
        selection: $selection,
        optionTitle: optionTitle,
        optionIdentifier: optionIdentifier
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    .accessibilityLabel(title)
    .accessibilityValue(optionTitle(selection))
  }
}

// MARK: - Accessibility helpers used by SidebarView

func sessionAccessibilityLabel(for session: SessionSummary) -> String {
  [
    session.context,
    session.projectName,
    session.checkoutDisplayName,
    session.status.title,
    session.sessionId,
  ].joined(separator: ", ")
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
