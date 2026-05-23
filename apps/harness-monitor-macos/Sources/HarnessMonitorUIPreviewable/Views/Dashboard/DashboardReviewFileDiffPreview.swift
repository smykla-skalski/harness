import HarnessMonitorKit
import SwiftUI

/// Lightweight first-lines diff renderer. It deliberately avoids syntax
/// tokenization so a prewarmed preview can paint before the full diff loads.
struct DashboardReviewFileDiffPreview: View {
  let preview: ReviewFilePreview

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if preview.patch.isEmpty {
        Text("No patch preview").font(.caption).foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal) {
          Text(preview.patch)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("dashboardReviewFileDiffPreview")
      }
      footer
    }
  }

  @ViewBuilder private var footer: some View {
    if preview.hasMore {
      Text("Showing first \(preview.lineCount) lines. Full diff is loading.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
