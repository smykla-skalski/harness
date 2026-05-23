import HarnessMonitorKit
import SwiftUI

struct DashboardReviewReviewList: View {
  let reviews: [PullRequestReview]

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
            DashboardReviewReviewerPill(review: review)
          }
        }
      }
      .frame(maxWidth: DashboardReviewsVisualMetrics.checksMaxWidth, alignment: .leading)
    }
  }

  private var summary: String {
    let approvals = reviews.count { $0.state == .approved }
    let changesRequested = reviews.count { $0.state == .changesRequested }
    if approvals > 0, changesRequested == 0 {
      return "\(approvals) \(approvals == 1 ? "approval" : "approvals") recorded"
    }
    if changesRequested > 0 {
      let noun = changesRequested == 1 ? "review" : "reviews"
      return "\(changesRequested) change-request \(noun) recorded"
    }
    return "\(reviews.count) \(reviews.count == 1 ? "review" : "reviews") recorded"
  }
}

private struct DashboardReviewReviewerPill: View {
  let review: PullRequestReview

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(review.author)
        .foregroundStyle(HarnessMonitorTheme.ink)
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
  }
}

struct DashboardReviewLabelStrip: View {
  let labels: [String]

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
        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
          DashboardReviewStatusPill(
            label: label,
            tint: HarnessMonitorTheme.secondaryInk,
            systemImage: "tag",
            isQuiet: true
          )
        }
      }
    }
  }
}
