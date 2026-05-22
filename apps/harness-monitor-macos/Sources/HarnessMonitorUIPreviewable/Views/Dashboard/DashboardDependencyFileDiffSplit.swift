import HarnessMonitorKit
import SwiftUI

/// Split-view diff with left (old) and right (new) panes side by side.
/// Falls back to the unified renderer when the proposed width is below
/// `minColumnPoints` so a narrow detail pane never produces unreadable
/// columns.
struct DashboardDependencyFileDiffSplit: View {
  let patch: DependencyUpdateFilePatch
  let language: HarnessDependencyFileLanguage
  var minColumnPoints: CGFloat = 280

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      if width / 2 < minColumnPoints {
        DashboardDependencyFileDiffUnified(patch: patch, language: language)
      } else {
        HStack(alignment: .top, spacing: 8) {
          column(text: leftColumnText())
          Divider()
          column(text: rightColumnText())
        }
      }
    }
    .frame(minHeight: 80)
    .accessibilityIdentifier("dashboardDependencyFileDiffSplit")
  }

  private func column(text: AttributedString) -> some View {
    ScrollView(.horizontal) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func leftColumnText() -> AttributedString {
    var result = AttributedString()
    for line in patch.patch.split(separator: "\n", omittingEmptySubsequences: false) {
      let leading = line.first
      if leading == "+" { continue }
      var fragment = AttributedString(String(line) + "\n")
      if leading == "-" {
        fragment.backgroundColor = .red.opacity(0.15)
      }
      fragment.foregroundColor = leading == "@" ? .secondary : .primary
      result += fragment
    }
    return result
  }

  private func rightColumnText() -> AttributedString {
    var result = AttributedString()
    for line in patch.patch.split(separator: "\n", omittingEmptySubsequences: false) {
      let leading = line.first
      if leading == "-" { continue }
      var fragment = AttributedString(String(line) + "\n")
      if leading == "+" {
        fragment.backgroundColor = .green.opacity(0.15)
      }
      fragment.foregroundColor = leading == "@" ? .secondary : .primary
      result += fragment
    }
    return result
  }
}
