import HarnessMonitorKit
import SwiftUI

/// Sidebar file tree for PRs with more than `treeMinimumFileCount`
/// files. Click-to-scroll handing is owned by the parent via
/// `onSelect`; expansion state lives on the per-PR view model so
/// SceneStorage's UserDefaults churn never fires.
struct DashboardDependencyFilesTree: View {
  let viewModel: DependencyUpdateFilesViewModel
  let onSelect: (String) -> Void

  static let treeMinimumFileCount = 8

  var body: some View {
    Group {
      if viewModel.files.count < Self.treeMinimumFileCount {
        EmptyView()
      } else {
        ScrollView {
          ForEach(buildNodes(), id: \.id) { node in
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
        .accessibilityIdentifier("dashboardDependencyFilesTree")
      }
    }
  }

  private func buildNodes() -> [Node] {
    var root = Node(name: "", fullPath: "", children: [])
    for file in viewModel.files {
      let segments = file.path.split(separator: "/").map(String.init)
      insert(into: &root, segments: segments, fullPath: file.path)
    }
    return root.children
  }

  private func insert(into node: inout Node, segments: [String], fullPath: String) {
    guard let first = segments.first else { return }
    let prefix = node.fullPath.isEmpty ? first : "\(node.fullPath)/\(first)"
    if segments.count == 1 {
      node.children.append(
        Node(name: first, fullPath: fullPath, children: [])
      )
      return
    }
    if let index = node.children.firstIndex(where: { $0.name == first }) {
      var child = node.children[index]
      insert(into: &child, segments: Array(segments.dropFirst()), fullPath: fullPath)
      node.children[index] = child
    } else {
      var child = Node(name: first, fullPath: prefix, children: [])
      insert(into: &child, segments: Array(segments.dropFirst()), fullPath: fullPath)
      node.children.append(child)
    }
  }

  fileprivate struct Node: Identifiable {
    var id: String { fullPath.isEmpty ? name : fullPath }
    let name: String
    let fullPath: String
    var children: [Self]
  }
}

private struct TreeRow: View {
  let node: DashboardDependencyFilesTree.Node
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
