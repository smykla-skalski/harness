import SwiftUI

struct TaskBoardReviewStaleHeadCard: View {
  let repository: String
  let reportHead: String
  let currentHead: String?
  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("Report is for an older revision")
          .font(captionSemibold)
        revisionLinks
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HarnessMonitorTheme.caution.opacity(0.12), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(HarnessMonitorTheme.caution.opacity(0.3))
    }
    .accessibilityLabel("Report is for an older pull request revision")
  }

  private var revisionLinks: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text("Reviewed")
      revisionLink(reportHead)
      if let currentHead {
        Text("·")
        Text("Current")
        revisionLink(currentHead)
      }
    }
    .font(captionFont.monospaced())
    .lineLimit(1)
  }

  @ViewBuilder
  private func revisionLink(_ revision: String) -> some View {
    if let destination = TaskBoardReviewGitHubLinks.revision(
      repository: repository,
      revision: revision
    ) {
      Link(revision.shortRevision, destination: destination)
        .foregroundStyle(HarnessMonitorTheme.accent)
        .help("Open revision \(revision) on GitHub")
    } else {
      Text(revision.shortRevision)
    }
  }
}

extension String {
  fileprivate var shortRevision: String {
    String(prefix(8))
  }
}
