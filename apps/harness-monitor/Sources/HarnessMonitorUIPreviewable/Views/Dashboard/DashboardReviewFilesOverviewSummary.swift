import HarnessMonitorKit
import SwiftUI

struct DashboardReviewFilesOverviewSummary: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let pullRequestID: String
  let repositoryID: String
  let onOpenFiles: () -> Void

  @Environment(\.fontScale)
  private var fontScale
  @State private var threadIndexCache = DashboardReviewFileThreadIndexCache()
  @State private var summaryCache = DashboardReviewFilesSummaryCache()

  var body: some View {
    let viewModel = store.viewModel(forPullRequest: pullRequestID)
    let timeline = store.reviewTimelineViewModel(for: pullRequestID)
    let threadIndex = threadIndexCache.index(
      for: timeline
    )
    let summary = summaryCache.summary(
      files: viewModel.files,
      viewedByPath: viewModel.viewedByPath,
      threadIndex: threadIndex,
      key: DashboardReviewFilesSummaryKey(
        filesRevision: viewModel.filesRevision,
        viewedStateRevision: viewModel.viewedStateRevision,
        timelineRevision: timeline.revision
      )
    )

    VStack(alignment: .leading, spacing: 10) {
      statusRow(viewModel: viewModel, summary: summary)
      chipWrap(summary: summary)
      Button {
        onOpenFiles()
      } label: {
        Label("Open Files", systemImage: "doc.text.magnifyingglass")
      }
      .controlSize(.small)
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .help("Open the dedicated Files review mode")
    }
    .task(id: pullRequestID) {
      guard store.connectionState == .online else { return }
      await store.prepareReviewFiles(pullRequestID: pullRequestID)
    }
    .accessibilityIdentifier("dashboardReviewFilesOverviewSummary")
  }

  private func statusRow(
    viewModel: ReviewFilesViewModel,
    summary: DashboardReviewFilesSummary
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "doc.on.doc")
        .foregroundStyle(.secondary)
      Text(statusText(viewModel: viewModel, summary: summary))
        .font(HarnessMonitorTextSize.scaledFont(.callout, by: fontScale))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if summary.unresolvedThreads > 0 {
        DashboardReviewFilesSummaryChip(
          systemImage: "text.bubble",
          title: "\(summary.unresolvedThreads) unresolved",
          tint: .orange
        )
      }
    }
  }

  private func chipWrap(summary: DashboardReviewFilesSummary) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        DashboardReviewFilesSummaryChip(
          systemImage: "plus.forwardslash.minus",
          title: "+\(summary.additions) -\(summary.deletions)"
        )
        DashboardReviewFilesSummaryChip(
          systemImage: "checkmark.circle",
          title: "\(summary.viewed) viewed"
        )
        DashboardReviewFilesSummaryChip(
          systemImage: "circle",
          title: "\(summary.unviewed) unviewed"
        )
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          bucketChips(summary: summary)
        }
        VStack(alignment: .leading, spacing: 6) {
          bucketChips(summary: summary)
        }
      }
    }
  }

  @ViewBuilder
  private func bucketChips(summary: DashboardReviewFilesSummary) -> some View {
    ForEach(DashboardReviewFileBucket.allCases, id: \.self) { bucket in
      if let count = summary.buckets[bucket], count > 0 {
        DashboardReviewFilesSummaryChip(
          systemImage: bucket.systemImage,
          title: "\(count) \(bucket.rawValue.lowercased())"
        )
      }
    }
  }

  private func statusText(
    viewModel: ReviewFilesViewModel,
    summary: DashboardReviewFilesSummary
  ) -> String {
    switch viewModel.state {
    case .idle, .loading:
      return "Files load automatically; open Files mode to review code."
    case .loaded:
      return "\(summary.total) changed files are ready in the dedicated Files mode."
    case .error(let message):
      return message
    }
  }
}
