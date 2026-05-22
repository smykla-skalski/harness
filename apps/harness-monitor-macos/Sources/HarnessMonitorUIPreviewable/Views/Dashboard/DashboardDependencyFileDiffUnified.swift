import HarnessMonitorKit
import SwiftUI

/// Unified-diff renderer that emits one `Text(AttributedString)` per
/// patch. Whole-patch tokenization runs off-main via
/// `SyntaxHighlightCache` so concurrent file cards reuse the same
/// token array for repeat renders. Per-line backgrounds come from
/// `AttributedString` runs - keeps a single Text view per patch and
/// lets TextKit virtualize the large body.
struct DashboardDependencyFileDiffUnified: View {
  let patch: DependencyUpdateFilePatch
  let language: HarnessDependencyFileLanguage

  @State private var attributed: AttributedString?

  var body: some View {
    if patch.patch.isEmpty {
      Text("No patch content").font(.caption).foregroundStyle(.secondary)
    } else {
      ScrollView(.horizontal) {
        Text(attributed ?? AttributedString(patch.patch))
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("dashboardDependencyFileDiffUnified")
      .task(id: patch.patch) {
        attributed = await Self.tokenize(patch: patch.patch)
      }
      if patch.truncated {
        Text("Truncated by GitHub at 3000 lines. Open the PR on github.com for the full diff.")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  static func tokenize(patch: String) async -> AttributedString {
    let tokens = await SyntaxHighlightCache.shared.tokenize(patch, language: .diff)
    return attributedDiff(from: tokens)
  }

  static func attributedDiff(from tokens: [HarnessCodeToken]) -> AttributedString {
    var result = AttributedString()
    for token in tokens {
      var fragment = AttributedString(token.text)
      switch token.kind {
      case .inserted:
        fragment.backgroundColor = .green.opacity(0.15)
        fragment.foregroundColor = .primary
      case .deleted:
        fragment.backgroundColor = .red.opacity(0.15)
        fragment.foregroundColor = .primary
      case .heading:
        fragment.foregroundColor = .secondary
      default:
        fragment.foregroundColor = .primary
      }
      result += fragment
    }
    return result
  }
}
