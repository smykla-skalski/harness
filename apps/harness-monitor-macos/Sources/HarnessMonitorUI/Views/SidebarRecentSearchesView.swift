import HarnessMonitorKit
import SwiftData
import SwiftUI

struct SidebarRecentSearchesHeader: View {
  let searchText: Binding<String>
  let isPersistenceAvailable: Bool
  let searchFocus: FocusState<Bool>.Binding
  let submitSearch: () -> Void
  let applyQuery: (String) -> Void
  let clearHistory: () -> Void
  @Query(sort: \RecentSearch.lastUsedAt, order: .reverse)
  private var recentSearches: [RecentSearch]

  private var recentSearchQueries: [String] {
    guard isPersistenceAvailable else {
      return []
    }
    return Array(recentSearches.prefix(5).map(\.query))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      SidebarInlineSearchField(
        searchText: searchText,
        searchFocus: searchFocus,
        submitSearch: submitSearch
      )

      if !recentSearchQueries.isEmpty {
        SidebarRecentSearchesView(
          queries: recentSearchQueries,
          isPersistenceAvailable: isPersistenceAvailable,
          applyQuery: applyQuery,
          clearHistory: clearHistory
        )
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.sectionSpacing)
    .padding(.top, HarnessMonitorTheme.spacingXL)
    .padding(.bottom, HarnessMonitorTheme.sectionSpacing)
  }
}

private struct SidebarInlineSearchField: View {
  let searchText: Binding<String>
  let searchFocus: FocusState<Bool>.Binding
  let submitSearch: () -> Void

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)

      TextField("Search sessions, projects, leaders", text: searchText)
        .textFieldStyle(.plain)
        .focused(searchFocus)
        .onSubmit(submitSearch)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarSearchField)

      if !searchText.wrappedValue.isEmpty {
        Button {
          searchText.wrappedValue = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .background {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        style: .continuous
      )
      .fill(.primary.opacity(0.04))
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
          style: .continuous
        )
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
      }
    }
  }
}

struct SidebarRecentSearchesView: View {
  let queries: [String]
  let isPersistenceAvailable: Bool
  let applyQuery: (String) -> Void
  let clearHistory: () -> Void
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack {
        Text("Recent Searches")
          .font(scaled(.caption.bold()))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)

        Spacer()

        if isPersistenceAvailable {
          Button("Clear", action: clearHistory)
            .harnessDismissButtonStyle()
            .font(scaled(.caption))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearSearchHistoryButton)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(queries, id: \.self) { query in
            Button {
              applyQuery(query)
            } label: {
              Text(verbatim: query)
                .lineLimit(1)
                .padding(.horizontal, HarnessMonitorTheme.spacingSM)
                .padding(.vertical, HarnessMonitorTheme.spacingXS)
            }
            .harnessAccessoryButtonStyle()
          }
        }
      }
    }
  }

  private func scaled(_ font: Font) -> Font {
    HarnessMonitorTextSize.scaledFont(font, by: fontScale)
  }
}
