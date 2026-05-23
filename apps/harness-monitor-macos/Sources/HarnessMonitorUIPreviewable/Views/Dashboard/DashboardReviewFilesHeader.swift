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
        systemImage: "plus.circle.fill",
        label: "+\(totalAdditions)",
        tint: HarnessMonitorTheme.success
      )
      countChip(
        systemImage: "minus.circle.fill",
        label: "-\(totalDeletions)",
        tint: HarnessMonitorTheme.danger
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
      ForEach(ReviewFilesSortMode.allCases, id: \.self) { mode in
        Button(
          action: { viewModel.applySort(mode) },
          label: {
            Label(label(for: mode), systemImage: viewModel.sortMode == mode ? "checkmark" : "")
          }
        )
      }
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
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
      HarnessMonitorTheme.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 6)
    )
  }

  private var filterToggles: some View {
    HStack(spacing: 10) {
      Toggle("Hide generated files", isOn: $filter.hideGenerated)
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(filter.hideGenerated ? "Generated files are hidden" : "Generated files are shown")
      Toggle("Hide whitespace-only", isOn: $filter.hideWhitespaceOnly)
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(
          filter.hideWhitespaceOnly
            ? "Whitespace-only file changes are hidden"
            : "Whitespace-only file changes are shown"
        )
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

  private var totalAdditions: UInt32 {
    viewModel.files.reduce(into: 0) { $0 += $1.additions }
  }

  private var totalDeletions: UInt32 {
    viewModel.files.reduce(into: 0) { $0 += $1.deletions }
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
