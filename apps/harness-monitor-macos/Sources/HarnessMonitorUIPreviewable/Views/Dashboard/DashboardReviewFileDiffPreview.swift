import HarnessMonitorKit
import SwiftUI

/// First-lines diff renderer that reuses the full diff highlighter while
/// the daemon fetches the remaining patch body in the background.
struct DashboardReviewFileDiffPreview: View {
  let preview: ReviewFilePreview
  let viewMode: FilesViewMode
  let language: HarnessReviewFileLanguage
  let fontScale: CGFloat
  var threads: [DashboardReviewFileThreadAnchor] = []
  var repositoryFullName: String?
  let isLoadingFullPatch: Bool
  let fullPatchFailed: Bool
  var fillsAvailableSpace: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if preview.patch.isEmpty {
        Text("No patch preview").font(.caption).foregroundStyle(.secondary)
      } else {
        diffPreview
      }
      footer
    }
    .frame(
      maxWidth: .infinity,
      maxHeight: fillsAvailableSpace ? .infinity : nil,
      alignment: .topLeading
    )
    .accessibilityIdentifier("dashboardReviewFileDiffPreview")
  }

  @ViewBuilder private var diffPreview: some View {
    if viewMode == .split {
      DashboardReviewFileDiffSplit(
        patch: preview.projectedPatch,
        language: language,
        fontScale: fontScale,
        threads: threads,
        repositoryFullName: repositoryFullName,
        fillsAvailableSpace: fillsAvailableSpace
      )
    } else {
      DashboardReviewFileDiffUnified(
        patch: preview.projectedPatch,
        language: language,
        fontScale: fontScale,
        threads: threads,
        repositoryFullName: repositoryFullName,
        fillsAvailableSpace: fillsAvailableSpace
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
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
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
