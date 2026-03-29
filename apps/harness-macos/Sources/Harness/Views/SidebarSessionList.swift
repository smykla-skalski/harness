import HarnessKit
import Observation
import SwiftUI

struct SidebarSessionList: View {
  @Bindable var store: HarnessStore

  private var activeFilterSummary: String {
    let visibleCount = store.filteredSessionCount
    let totalCount = store.sessions.count
    let isAnyFilterActive =
      store.selectedSavedSearchID != nil
      || !store.searchText.isEmpty
      || store.sessionFilter != .active
      || store.sessionFocusFilter != .all
    if isAnyFilterActive {
      return "\(visibleCount) visible of \(totalCount)"
    }
    return "\(totalCount) indexed"
  }

  private var isFiltered: Bool {
    store.selectedSavedSearchID != nil
      || !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.sessionFilter != .active
      || store.sessionFocusFilter != .all
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      filterSlice
      sessionList
      savedSearchSlice
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
          .harnessAccessoryButtonStyle(tint: HarnessTheme.accent)
          .controlSize(.small)
          .accessibilityIdentifier(HarnessAccessibility.sidebarClearFiltersButton)
        }
      }

      TextField("Search sessions, projects, leaders", text: $store.searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("harness.sidebar.search")

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
                store.selectedSavedSearchID = nil
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
                store.selectedSavedSearchID = nil
              }
            }
          }
        }
      }
    }
    .padding(14)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 22,
        fillOpacity: 0.05,
        strokeOpacity: 0.09
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityFrameMarker("\(HarnessAccessibility.sidebarFiltersCard).frame")
  }

  private var savedSearchSlice: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Saved Searches")
        .font(.caption.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)

      HarnessGlassContainer(spacing: 8) {
        HarnessWrapLayout(spacing: 8, lineSpacing: 8) {
          ForEach(store.savedSearches) { search in
            savedSearchButton(search)
          }
        }
      }
    }
  }

  private var sessionList: some View {
    Group {
      if store.sessions.isEmpty {
        emptyState(
          title: "No sessions indexed yet",
          message: "Start the daemon or refresh after launching a harness session."
        )
      } else if store.groupedSessions.isEmpty {
        emptyState(
          title: "No sessions match",
          message: "Clear or adjust the current search and filter slice."
        )
      } else {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(store.groupedSessions) { group in
            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text(group.project.name)
                  .font(.system(.headline, design: .serif, weight: .semibold))
                  .foregroundStyle(HarnessTheme.sidebarHeader)
                Spacer()
                Text("\(group.sessions.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(HarnessTheme.sidebarMuted)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background {
                HarnessInsetPanelBackground(
                  cornerRadius: 16,
                  fillOpacity: 0.04,
                  strokeOpacity: 0.14
                )
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
                  VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                      Text(session.context)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                      Spacer(minLength: 12)
                      Circle()
                        .fill(statusColor(for: session.status))
                        .frame(width: 10, height: 10)
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
                  .foregroundStyle(HarnessTheme.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(14)
                  .background {
                    HarnessInteractiveCardBackground(
                      cornerRadius: 18,
                      tint: store.selectedSessionID == session.sessionId ? HarnessTheme.accent : nil
                    )
                  }
                  .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .accessibilityIdentifier(HarnessAccessibility.sessionRow(session.sessionId))
                .accessibilityFrameMarker(
                  "\(HarnessAccessibility.sessionRow(session.sessionId)).frame"
                )
                .buttonStyle(.plain)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityFrameMarker(HarnessAccessibility.sidebarSessionListContent)
      }
    }
  }

  private func filterSection<Content: View>(
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
    Button(action: action) {
      Text(title)
        .font(.system(.callout, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.88)
        .padding(.horizontal, HarnessControlMetrics.chipHorizontalPadding)
        .padding(.vertical, HarnessControlMetrics.chipVerticalPadding)
        .frame(minHeight: HarnessControlMetrics.chipMinHeight)
        .fixedSize(horizontal: true, vertical: true)
    }
    .buttonBorderShape(.roundedRectangle(radius: 12))
    .harnessFilterChipButtonStyle(isSelected: isSelected)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityIdentifier(identifier)
    .accessibilityFrameMarker("\(identifier).frame")
    .accessibilityValue(
      isSelected ? "selected accent-on-light" : "not selected ink-on-panel"
    )
  }

  private func savedSearchButton(_ search: SessionSavedSearch) -> some View {
    Button {
      store.applySavedSearch(search)
    } label: {
      Label(search.title, systemImage: savedSearchSymbol(for: search))
        .font(.system(.callout, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.88)
        .padding(.horizontal, HarnessControlMetrics.chipHorizontalPadding)
        .padding(.vertical, HarnessControlMetrics.chipVerticalPadding)
        .frame(minHeight: HarnessControlMetrics.chipMinHeight)
        .fixedSize(horizontal: true, vertical: true)
    }
    .buttonBorderShape(.roundedRectangle(radius: 12))
    .harnessFilterChipButtonStyle(isSelected: store.selectedSavedSearchID == search.id)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .help(search.summary)
    .accessibilityLabel(search.title)
    .accessibilityIdentifier(HarnessAccessibility.sidebarSavedSearchButton(search.id))
    .accessibilityFrameMarker(
      "\(HarnessAccessibility.sidebarSavedSearchButton(search.id)).frame"
    )
    .accessibilityValue(
      store.selectedSavedSearchID == search.id ? "selected" : "not selected"
    )
  }

  private func savedSearchSymbol(for search: SessionSavedSearch) -> String {
    if store.selectedSavedSearchID == search.id {
      return "checkmark.circle.fill"
    }
    return "line.3.horizontal.decrease.circle"
  }
}

extension SidebarSessionList {
  fileprivate func emptyState(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(.headline, design: .rounded, weight: .semibold))
      Text(message)
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(14)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 22,
        fillOpacity: 0.07,
        strokeOpacity: 0.10
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sidebarEmptyState)
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
