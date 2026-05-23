import HarnessMonitorKit
import SwiftUI

/// Top-bar of the Reviews > Files section: aggregate counts, filter
/// input, sort dropdown, and the "Mark all viewed" / "Reset" affordances.
struct DashboardReviewFilesHeader: View {
  let viewModel: ReviewFilesViewModel
  @Bindable var filter: DashboardReviewFilesFilterState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      statsRow
      controlsRow
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesHeader)
  }

  private var statsRow: some View {
    HStack(spacing: 12) {
      countChip(
        systemImage: "doc.on.doc",
        label: "\(viewModel.filteredFiles.count) visible of \(viewModel.files.count) files"
      )
      countChip(
        systemImage: "checkmark.circle",
        label: "\(viewedCount) viewed",
        tint: HarnessMonitorTheme.secondaryInk
      )
      Spacer(minLength: 0)
    }
  }

  private var controlsRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 10) {
        filterField
          .frame(minWidth: 260, idealWidth: 360, maxWidth: 440)
        Spacer(minLength: 8)
        filterToggles
        sortMenu
      }
      VStack(alignment: .leading, spacing: 8) {
        filterField
        HStack(spacing: 10) {
          filterToggles
          Spacer(minLength: 8)
          sortMenu
        }
      }
    }
  }

  private var sortMenu: some View {
    Menu {
      Picker(
        "Sort",
        selection: Binding(
          get: { viewModel.sortMode },
          set: { viewModel.applySort($0) }
        )
      ) {
        ForEach(ReviewFilesSortMode.allCases, id: \.self) { mode in
          Text(label(for: mode)).tag(mode)
        }
      }
      .pickerStyle(.inline)
    } label: {
      Label("Sort: \(label(for: viewModel.sortMode))", systemImage: "arrow.up.arrow.down")
    }
    .controlSize(.small)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesSortMenu)
  }

  private var filterField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Filter by path", text: $filter.text)
        .textFieldStyle(.plain)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewFilesFilterField)
      if !filter.text.isEmpty {
        Button(
          action: { filter.clearText() },
          label: {
            Image(systemName: "xmark.circle.fill")
          }
        )
        .harnessPlainButtonStyle()
        .accessibilityLabel("Clear filter")
      }
    }
    .padding(8)
    .background(
      HarnessMonitorTheme.ink.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(HarnessMonitorTheme.controlBorder, lineWidth: 1)
    }
  }

  private var filterToggles: some View {
    HStack(spacing: 10) {
      Toggle(isOn: $filter.hideGenerated) {
        Text("Hide generated files")
          .allowsTightening(true)
          .minimumScaleFactor(0.9)
          .lineLimit(1)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .help(
        "Hide files matching the generated-files patterns "
          + "(e.g. package-lock.json, yarn.lock, vendor/, dist/). "
          + "Configure patterns in Settings > Reviews > Files."
      )
      Toggle(isOn: $filter.hideWhitespaceOnly) {
        Text("Hide whitespace-only")
          .allowsTightening(true)
          .minimumScaleFactor(0.9)
          .lineLimit(1)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .help("Hide files whose only differences are whitespace or trailing-newline changes.")
    }
  }

  private func countChip(
    systemImage: String,
    label: String,
    tint: Color = .secondary
  ) -> some View {
    Label(label, systemImage: systemImage)
      .font(.subheadline)
      .foregroundStyle(tint)
  }

  private var viewedCount: Int {
    viewModel.files.reduce(into: 0) { count, file in
      let state = viewModel.viewedByPath[file.path] ?? file.viewerViewedState
      if state == .viewed { count += 1 }
    }
  }

  private func label(for mode: ReviewFilesSortMode) -> String {
    switch mode {
    case .path: return "Path"
    case .lineChangesDescending: return "Line changes ↓"
    case .viewedFirst: return "Viewed first"
    case .unviewedFirst: return "Unviewed first"
    }
  }
}
