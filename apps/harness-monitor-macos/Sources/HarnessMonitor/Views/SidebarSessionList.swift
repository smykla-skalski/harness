import HarnessMonitorKit
import Observation
import SwiftUI

struct SidebarSessionList: View {
  @Bindable var store: MonitorStore

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
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityIdentifier(MonitorAccessibility.sidebarSessionList)
  }

  private var filterSlice: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Search & Filters")
            .font(.system(.headline, design: .rounded, weight: .semibold))
          Text(activeFilterSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isFiltered {
          Button("Clear") {
            store.resetFilters()
          }
          .font(.caption.bold())
          .monitorAccessoryButtonStyle(tint: MonitorTheme.accent)
          .controlSize(.small)
          .accessibilityIdentifier(MonitorAccessibility.sidebarClearFiltersButton)
        }
      }

      filterSection(title: "Status") {
        MonitorGlassContainer(spacing: 8) {
          MonitorWrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(MonitorStore.SessionFilter.allCases) { filter in
              filterChip(
                title: filter.title,
                isSelected: store.sessionFilter == filter,
                identifier: MonitorAccessibility.sidebarFilterChip(filter.rawValue)
              ) {
                store.sessionFilter = filter
                store.selectedSavedSearchID = nil
              }
            }
          }
        }
      }

      filterSection(title: "Focus") {
        MonitorGlassContainer(spacing: 8) {
          MonitorWrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(SessionFocusFilter.allCases) { filter in
              filterChip(
                title: filter.title,
                isSelected: store.sessionFocusFilter == filter,
                identifier: MonitorAccessibility.sidebarFocusChip(filter.rawValue)
              ) {
                store.sessionFocusFilter = filter
                store.selectedSavedSearchID = nil
              }
            }
          }
        }
      }

      filterSection(title: "Saved Searches") {
        MonitorGlassContainer(spacing: 10) {
          MonitorAdaptiveGridLayout(minimumColumnWidth: 156, maximumColumns: 2, spacing: 10) {
            ForEach(store.savedSearches) { search in
              savedSearchButton(search)
            }
          }
        }
      }
    }
    .padding(14)
    .background {
      MonitorInsetPanelBackground(
        cornerRadius: 22,
        fillOpacity: 0.05,
        strokeOpacity: 0.09
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sidebarFiltersCard)
    .accessibilityFrameMarker(MonitorAccessibility.sidebarFiltersCard)
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
                  .foregroundStyle(MonitorTheme.sidebarHeader)
                Spacer()
                Text("\(group.sessions.count)")
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(MonitorTheme.sidebarMuted)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background {
                MonitorInsetPanelBackground(
                  cornerRadius: 16,
                  fillOpacity: 0.04,
                  strokeOpacity: 0.14
                )
              }
              .accessibilityIdentifier(
                MonitorAccessibility.projectHeader(group.project.projectId)
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
                      .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                      labelChip("\(session.metrics.activeAgentCount) active")
                      labelChip("\(session.metrics.inProgressTaskCount) moving")
                      labelChip(formatTimestamp(session.lastActivityAt))
                    }
                  }
                  .foregroundStyle(MonitorTheme.ink)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(14)
                  .background {
                    MonitorInteractiveCardBackground(
                      cornerRadius: 18,
                      tint: store.selectedSessionID == session.sessionId ? MonitorTheme.accent : nil
                    )
                  }
                  .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .accessibilityIdentifier(MonitorAccessibility.sessionRow(session.sessionId))
                .accessibilityFrameMarker(MonitorAccessibility.sessionRow(session.sessionId))
                .buttonStyle(.plain)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityFrameMarker(MonitorAccessibility.sidebarSessionListContent)
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
        .foregroundStyle(.secondary)
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
        .padding(.horizontal, MonitorControlMetrics.chipHorizontalPadding)
        .padding(.vertical, MonitorControlMetrics.chipVerticalPadding)
        .frame(minHeight: MonitorControlMetrics.chipMinHeight)
        .fixedSize(horizontal: true, vertical: true)
    }
    .buttonBorderShape(.roundedRectangle(radius: 12))
    .monitorFilterChipButtonStyle(isSelected: isSelected)
    .controlSize(MonitorControlMetrics.compactControlSize)
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .accessibilityIdentifier(identifier)
    .accessibilityFrameMarker(identifier)
    .accessibilityValue(isSelected ? "selected" : "not selected")
  }

  private func savedSearchButton(_ search: SessionSavedSearch) -> some View {
    Button {
      store.applySavedSearch(search)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline) {
          Text(search.title)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
            .foregroundStyle(
              store.selectedSavedSearchID == search.id ? Color.white : MonitorTheme.sidebarHeader
            )
          Spacer()
          if store.selectedSavedSearchID == search.id {
            Circle()
              .fill(MonitorTheme.success)
              .frame(width: 8, height: 8)
          }
        }
        Text(search.summary)
          .font(.system(.footnote, design: .rounded, weight: .medium))
          .foregroundStyle(
            store.selectedSavedSearchID == search.id
              ? Color.white.opacity(0.84) : MonitorTheme.sidebarMuted
          )
          .lineLimit(2, reservesSpace: true)
      }
      .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
      .padding(12)
      .background {
        if store.selectedSavedSearchID == search.id {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(MonitorTheme.accent)
            .overlay {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MonitorTheme.accent.opacity(0.32), lineWidth: 1)
            }
        } else {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(MonitorTheme.surface)
            .overlay {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MonitorTheme.controlBorder, lineWidth: 1)
            }
        }
      }
    }
    .buttonStyle(.plain)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityLabel(search.title)
    .accessibilityIdentifier(MonitorAccessibility.sidebarSavedSearchButton(search.id))
    .accessibilityFrameMarker(MonitorAccessibility.sidebarSavedSearchButton(search.id))
    .accessibilityValue(
      store.selectedSavedSearchID == search.id ? "selected" : "not selected"
    )
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
      MonitorInsetPanelBackground(
        cornerRadius: 22,
        fillOpacity: 0.07,
        strokeOpacity: 0.10
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sidebarEmptyState)
  }

  fileprivate func labelChip(_ value: String) -> some View {
    Text(value)
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background {
        MonitorGlassCapsuleBackground()
      }
  }
}
