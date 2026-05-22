import HarnessMonitorKit
import SwiftUI

/// Top-bar of the Dependencies > Files section: aggregate counts, filter
/// input, sort dropdown, and the "Mark all viewed" / "Reset" affordances.
struct DashboardDependencyFilesHeader: View {
  let viewModel: DependencyUpdateFilesViewModel
  @Bindable var filter: DashboardDependencyFilesFilterState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        countChip(
          systemImage: "doc.on.doc",
          label: "\(viewModel.files.count) files"
        )
        countChip(
          systemImage: "plus.circle.fill",
          label: "+\(totalAdditions)",
          tint: .green
        )
        countChip(
          systemImage: "minus.circle.fill",
          label: "-\(totalDeletions)",
          tint: .red
        )
        Spacer(minLength: 0)
        sortMenu
      }
      filterBar
    }
    .accessibilityIdentifier("dashboardDependencyFilesHeader")
  }

  private var sortMenu: some View {
    Menu {
      ForEach(DependencyUpdateFilesSortMode.allCases, id: \.self) { mode in
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
    .accessibilityIdentifier("dashboardDependencyFilesSortMenu")
  }

  private var filterBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Filter by path", text: $filter.text)
        .textFieldStyle(.plain)
        .accessibilityIdentifier("dashboardDependencyFilesFilterField")
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
      Toggle("Hide generated", isOn: $filter.hideGenerated)
        .toggleStyle(.switch)
        .controlSize(.mini)
      Toggle("Hide whitespace", isOn: $filter.hideWhitespaceOnly)
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
    .padding(8)
    .background(
      HarnessMonitorTheme.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 6)
    )
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

  private func label(for mode: DependencyUpdateFilesSortMode) -> String {
    switch mode {
    case .path: return "Path"
    case .lineChangesDescending: return "Line changes ↓"
    case .viewedFirst: return "Viewed first"
    case .unviewedFirst: return "Unviewed first"
    }
  }
}
