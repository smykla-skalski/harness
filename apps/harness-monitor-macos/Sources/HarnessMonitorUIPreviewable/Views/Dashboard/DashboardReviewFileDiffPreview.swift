import HarnessMonitorKit
import SwiftUI

/// First-lines diff renderer that reuses the full diff highlighter while
/// the daemon fetches the remaining patch body in the background.
struct DashboardReviewFileDiffPreview: View {
  let preview: ReviewFilePreview
  let viewMode: FilesViewMode
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  let isLoadingFullPatch: Bool
  let fullPatchFailed: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if preview.patch.isEmpty {
        Text("No patch preview").font(.caption).foregroundStyle(.secondary)
      } else {
        diffPreview
      }
      footer
    }
    .accessibilityIdentifier("dashboardReviewFileDiffPreview")
  }

  @ViewBuilder private var diffPreview: some View {
    if viewMode == .split {
      DashboardReviewFileDiffSplit(
        patch: preview.projectedPatch,
        language: language,
        fontScale: fontScale
      )
    } else {
      DashboardReviewFileDiffUnified(
        patch: preview.projectedPatch,
        language: language,
        fontScale: fontScale
      )
    }
  }

  @ViewBuilder private var footer: some View {
    if preview.hasMore {
      HStack(spacing: 6) {
        if isLoadingFullPatch {
          ProgressView().controlSize(.mini)
        }
        Text(remainderMessage)
          .font(.caption2)
          .foregroundStyle(fullPatchFailed ? .orange : .secondary)
      }
    }
  }

  private var remainderMessage: String {
    if fullPatchFailed {
      return "Showing first \(preview.lineCount) lines; remaining lines are unavailable."
    }
    if isLoadingFullPatch {
      return "Loading remaining lines after the first \(preview.lineCount)."
    }
    return "Showing first \(preview.lineCount) lines."
  }
}
