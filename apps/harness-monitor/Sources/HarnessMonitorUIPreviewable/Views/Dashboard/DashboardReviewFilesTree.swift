import HarnessMonitorKit
import SwiftUI

/// Sidebar file tree for PRs with more than `treeMinimumFileCount`
/// files. Click-to-scroll handing is owned by the parent via
/// `onSelect`; expansion state lives on the per-PR view model so
/// SceneStorage's UserDefaults churn never fires.
struct DashboardReviewFilesTree: View {
  let viewModel: ReviewFilesViewModel
  let onSelect: (String) -> Void

  static let treeMinimumFileCount = 8

  var body: some View {
    Group {
      if viewModel.files.count < Self.treeMinimumFileCount {
        EmptyView()
      } else {
        ScrollView {
          ForEach(viewModel.fileTreeNodes, id: \.id) { node in
            TreeRow(
              node: node,
              depth: 0,
              expandedPaths: viewModel.expandedPaths,
              onToggle: { path in viewModel.toggleExpansion(path: path) },
              onSelect: onSelect
            )
          }
        }
        .frame(minWidth: 180, maxWidth: 240, maxHeight: 400)
        .accessibilityIdentifier("dashboardReviewFilesTree")
      }
    }
  }
}

private struct TreeRow: View {
  let node: ReviewFileTreeNode
  let depth: Int
  let expandedPaths: Set<String>
  let onToggle: (String) -> Void
  let onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Image(systemName: node.children.isEmpty ? "doc" : "folder")
          .foregroundStyle(.secondary)
        Button(action: handleTap) {
          Text(node.name).lineLimit(1)
        }
        .harnessPlainButtonStyle()
      }
      .padding(.leading, CGFloat(depth) * 12)
      if !node.children.isEmpty && expandedPaths.contains(node.fullPath) {
        ForEach(node.children, id: \.id) { child in
          Self(
            node: child,
            depth: depth + 1,
            expandedPaths: expandedPaths,
            onToggle: onToggle,
            onSelect: onSelect
          )
        }
      }
    }
  }

  private func handleTap() {
    if node.children.isEmpty {
      onSelect(node.fullPath)
    } else {
      onToggle(node.fullPath)
    }
  }
}
