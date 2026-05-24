import HarnessMonitorKit
import SwiftUI

struct DashboardReviewReviewList: View {
  let reviews: [PullRequestReview]
  let viewerLogin: String?
  let canReRequestReview: Bool
  let onReRequestReview: ((String) -> Void)?

  init(
    reviews: [PullRequestReview],
    viewerLogin: String? = nil,
    canReRequestReview: Bool = false,
    onReRequestReview: ((String) -> Void)? = nil
  ) {
    self.reviews = reviews
    self.viewerLogin = viewerLogin
    self.canReRequestReview = canReRequestReview
    self.onReRequestReview = onReRequestReview
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
            let isViewer = viewerLogin?.caseInsensitiveCompare(review.author) == .orderedSame
            DashboardReviewReviewerPill(
              review: review,
              isViewer: isViewer,
              canReRequestReview: canReRequestReview && !isViewer,
              onReRequestReview: onReRequestReview
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
    case (let approvalCount, 0):
      return "\(approvalCount) \(approvalCount == 1 ? "approval" : "approvals") recorded"
    case (0, let changesCount):
      let noun = changesCount == 1 ? "review" : "reviews"
      return "\(changesCount) change-request \(noun) recorded"
    case (let approvalCount, let changesCount):
      let approvalNoun = approvalCount == 1 ? "approval" : "approvals"
      let changeNoun = changesCount == 1 ? "change-request" : "change-requests"
      return "\(approvalCount) \(approvalNoun), \(changesCount) \(changeNoun) recorded"
    }
  }
}

private struct DashboardReviewReviewerPill: View {
  let review: PullRequestReview
  let isViewer: Bool
  let canReRequestReview: Bool
  let onReRequestReview: ((String) -> Void)?

  @Environment(HarnessMonitorStore.self)
  private var store

  private var avatarURL: URL? {
    review.authorAvatarURL ?? ReviewAvatarCache.fallbackAvatarURL(login: review.author)
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      AvatarImageView(
        login: review.author,
        avatarURL: avatarURL,
        size: 16,
        loadImage: { login, avatarURL, targetPixel in
          await store.reviewAvatarImage(
            login: login,
            avatarURL: avatarURL,
            targetPixel: targetPixel
          )
        }
      )
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
    .harnessOpticallyBalancedVerticalPadding(4)
    .background(
      review.state.tint.opacity(0.10),
      in: RoundedRectangle(cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DashboardReviewsVisualMetrics.pillCornerRadius)
        .strokeBorder(review.state.tint.opacity(0.24), lineWidth: 1)
    }
    .contextMenu {
      if canReRequestReview, let onReRequestReview {
        Button("Re-request review from @\(review.author)") {
          onReRequestReview(review.author)
        }
      }
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
  private let labelByName: [String: ReviewRepositoryLabel]

  init(labels: [String], repositoryLabels: [ReviewRepositoryLabel] = []) {
    self.labels = labels
    self.repositoryLabels = repositoryLabels
    labelByName = Dictionary(
      repositoryLabels.map { ($0.name, $0) },
      uniquingKeysWith: { first, _ in first }
    )
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

/// Single shared chip used by both the detail-pane label strip and the
/// dashboard list row's label strip.
///
/// When a `descriptor` is supplied (detail pane has access to the repository
/// label palette), the chip prefixes a colour swatch dot derived from the
/// descriptor; without a descriptor (list row mode), the swatch falls back
/// to `secondaryInk` so the chip still reads as a tag instead of an
/// undifferentiated pill.
///
/// Text colour is always primary `ink` so the chip remains legible even
/// when the surrounding tint is muted — replacing the prior
/// `DashboardReviewStatusPill(tint: .secondaryInk)` rendering that painted
/// both background and text in the same grey.
///
/// `showsSwatch == false` collapses the swatch dot entirely so callers that
/// don't have descriptor colours can opt out of the placeholder dot.
struct DashboardReviewLabelChip: View {
  let name: String
  let descriptor: ReviewRepositoryLabel?
  let showsSwatch: Bool

  init(name: String, descriptor: ReviewRepositoryLabel?, showsSwatch: Bool = true) {
    self.name = name
    self.descriptor = descriptor
    self.showsSwatch = showsSwatch
  }

  private var tint: Color {
    dashboardReviewsLabelSwatchColor(descriptor?.color)
      ?? HarnessMonitorTheme.secondaryInk
  }

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if showsSwatch {
        Circle()
          .fill(tint)
          .frame(width: 8, height: 8)
          .accessibilityHidden(true)
      }
      Text(name)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
        .harnessOpticalTextCenter()
    }
    .padding(.horizontal, 8)
    .harnessOpticallyBalancedVerticalPadding(4)
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
    .help(chipHelp)
    .accessibilityLabel(Text(name))
  }

  private var chipHelp: String {
    let description =
      descriptor?.description?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return description.isEmpty ? name : description
  }
}
