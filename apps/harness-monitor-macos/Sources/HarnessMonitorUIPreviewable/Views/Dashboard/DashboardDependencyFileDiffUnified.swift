import HarnessMonitorKit
import SwiftUI

/// Unified-diff renderer that emits one `Text(AttributedString)` per
/// hunk. TextKit virtualizes long bodies internally, far faster than
/// LazyVStack-per-row. Per-line backgrounds are AttributedString runs
/// on the inserted/deleted line ranges so we keep a single Text view
/// per hunk.
struct DashboardDependencyFileDiffUnified: View {
  let patch: DependencyUpdateFilePatch
  let language: HarnessDependencyFileLanguage

  var body: some View {
    if patch.patch.isEmpty {
      Text("No patch content").font(.caption).foregroundStyle(.secondary)
    } else {
      ScrollView(.horizontal) {
        Text(makeAttributedDiff(patch.patch))
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("dashboardDependencyFileDiffUnified")
      if patch.truncated {
        Text("Truncated by GitHub at 3000 lines. Open the PR on github.com for the full diff.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  private func makeAttributedDiff(_ source: String) -> AttributedString {
    var result = AttributedString()
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      var fragment = AttributedString(String(line) + "\n")
      let leading = line.first
      switch leading {
      case "+":
        fragment.backgroundColor = .green.opacity(0.15)
        fragment.foregroundColor = .primary
      case "-":
        fragment.backgroundColor = .red.opacity(0.15)
        fragment.foregroundColor = .primary
      case "@":
        fragment.foregroundColor = .secondary
      default:
        fragment.foregroundColor = .primary
      }
      result += fragment
    }
    return result
  }
}
