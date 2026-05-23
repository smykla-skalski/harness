import HarnessMonitorKit
import SwiftUI

struct DashboardReviewReviewList: View {
  let reviews: [PullRequestReview]
  let viewerLogin: String?

  init(reviews: [PullRequestReview], viewerLogin: String? = nil) {
    self.reviews = reviews
    self.viewerLogin = viewerLogin
  }

  var body: some View {
    if reviews.isEmpty {
      Text("No reviews yet")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text(summary)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.spacingSM,
          lineSpacing: HarnessMonitorTheme.spacingSM
        ) {
          ForEach(reviews) { review in
            DashboardReviewReviewerPill(
              review: review,
              isViewer: viewerLogin?.caseInsensitiveCompare(review.author) == .orderedSame
            )
          }
        }
      }
      .frame(maxWidth: DashboardReviewsVisualMetrics.sectionMaxWidth, alignment: .leading)
    }
  }

  private var summary: String {
    let approvals = reviews.count { $0.state == .approved }
    let changesRequested = reviews.count { $0.state == .changesRequested }
    switch (approvals, changesRequested) {
    case (0, 0):
      return "\(reviews.count) \(reviews.count == 1 ? "review" : "reviews") recorded"
    case (let a, 0):
      return "\(a) \(a == 1 ? "approval" : "approvals") recorded"
    case (0, let c):
      let noun = c == 1 ? "review" : "reviews"
      return "\(c) change-request \(noun) recorded"
    case (let a, let c):
      let approvalNoun = a == 1 ? "approval" : "approvals"
      let changeNoun = c == 1 ? "change-request" : "change-requests"
      return "\(a) \(approvalNoun), \(c) \(changeNoun) recorded"
    }
  }
}

private struct DashboardReviewReviewerPill: View {
  let review: PullRequestReview
  let isViewer: Bool

  private var avatarURL: URL? {
    URL(string: "https://github.com/\(review.author).png?size=24")
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      AsyncImage(url: avatarURL) { image in
        image
          .resizable()
          .interpolation(.high)
      } placeholder: {
        Image(systemName: "person.crop.circle.fill")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      .frame(width: 16, height: 16)
      .clipShape(Circle())
      .accessibilityHidden(true)
      Text(review.author)
        .foregroundStyle(HarnessMonitorTheme.ink)
      if isViewer {
        Text("(you)")
          .foregroundStyle(HarnessMonitorTheme.accent)
      }
      Text(review.state.label)
        .foregroundStyle(review.state.tint)
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      review.state.tint.opacity(0.10),
      in: RoundedRectangle(cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius)
        .strokeBorder(review.state.tint.opacity(0.24), lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      Text(
        isViewer
          ? "\(review.author) (you) — \(review.state.label)"
          : "\(review.author) — \(review.state.label)"
      )
    )
  }
}

struct DashboardReviewLabelStrip: View {
  let labels: [String]
  let repositoryLabels: [ReviewRepositoryLabel]

  init(labels: [String], repositoryLabels: [ReviewRepositoryLabel] = []) {
    self.labels = labels
    self.repositoryLabels = repositoryLabels
  }

  private var labelByName: [String: ReviewRepositoryLabel] {
    Dictionary(uniqueKeysWithValues: repositoryLabels.map { ($0.name, $0) })
  }

  var body: some View {
    if labels.isEmpty {
      Text("No labels applied")
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(labels, id: \.self) { name in
          DashboardReviewLabelChip(
            name: name,
            descriptor: labelByName[name]
          )
        }
      }
    }
  }
}

private struct DashboardReviewLabelChip: View {
  let name: String
  let descriptor: ReviewRepositoryLabel?

  private var tint: Color {
    dashboardReviewsLabelSwatchColor(descriptor?.color)
      ?? HarnessMonitorTheme.secondaryInk
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(name)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      tint.opacity(0.10),
      in: RoundedRectangle(
        cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius
      )
    )
    .overlay {
      RoundedRectangle(cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius)
        .strokeBorder(tint.opacity(0.28), lineWidth: 1)
    }
    .help(descriptor?.description ?? "")
    .accessibilityLabel(Text(name))
  }
}
