import HarnessMonitorKit
import SwiftUI

public struct AwaitingReviewBadgeView: View {
  public let taskID: String
  public let awaitingReview: AwaitingReview

  public init(taskID: String, awaitingReview: AwaitingReview) {
    self.taskID = taskID
    self.awaitingReview = awaitingReview
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: "hourglass")
        .imageScale(.small)
      Text("Awaiting Review")
        .scaledFont(.caption.weight(.semibold))
    }
    .harnessPillPadding()
    .harnessContentPill(tint: HarnessMonitorTheme.caution)
    .foregroundStyle(HarnessMonitorTheme.caution)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.awaitingReviewBadge(taskID))
    .accessibilityLabel(Text("Awaiting review, submitted by \(awaitingReview.submitterAgentId)"))
  }
}

public struct ReviewerClaimBadgeView: View {
  public let taskID: String
  public let reviewer: ReviewerEntry

  public init(taskID: String, reviewer: ReviewerEntry) {
    self.taskID = taskID
    self.reviewer = reviewer
  }

  private var isSubmitted: Bool { reviewer.submittedAt != nil }

  private var accessibilityDescription: String {
    let state = isSubmitted ? "submitted" : "claimed"
    return "Reviewer \(reviewer.reviewerAgentId), runtime \(reviewer.reviewerRuntime), \(state)"
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: isSubmitted ? "checkmark.seal.fill" : "person.crop.circle.badge.clock")
        .imageScale(.small)
      Text("\(reviewer.reviewerRuntime) · \(reviewer.reviewerAgentId)")
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
    }
    .harnessPillPadding()
    .harnessContentPill(
      tint: isSubmitted ? HarnessMonitorTheme.success : HarnessMonitorTheme.accent
    )
    .foregroundStyle(
      isSubmitted ? HarnessMonitorTheme.success : HarnessMonitorTheme.accent
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.reviewerClaimBadge(taskID, runtime: reviewer.reviewerRuntime)
    )
    .accessibilityLabel(Text(accessibilityDescription))
  }
}

public struct ReviewerQuorumIndicatorView: View {
  public let taskID: String
  public let claim: ReviewClaim?
  public let required: Int

  public init(taskID: String, claim: ReviewClaim?, required: Int) {
    self.taskID = taskID
    self.claim = claim
    self.required = required
  }

  private var submittedCount: Int {
    claim?.reviewers.filter { $0.submittedAt != nil }.count ?? 0
  }

  private var claimedCount: Int { claim?.reviewers.count ?? 0 }

  private var tint: Color {
    submittedCount >= required ? HarnessMonitorTheme.success : HarnessMonitorTheme.accent
  }

  public var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: "person.2.fill")
        .imageScale(.small)
      Text("\(submittedCount)/\(required) submitted · \(claimedCount) claimed")
        .scaledFont(.caption.weight(.semibold))
    }
    .harnessPillPadding()
    .harnessContentPill(tint: tint)
    .foregroundStyle(tint)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.reviewerQuorumIndicator(taskID))
    .accessibilityLabel(
      Text(
        "Reviewer quorum: \(submittedCount) of \(required) submitted, \(claimedCount) claimed"
      )
    )
  }
}

public struct PartialAgreementChipView: View {
  public let point: ReviewPoint

  public init(point: ReviewPoint) {
    self.point = point
  }

  private var tint: Color {
    switch point.state {
    case .open:
      HarnessMonitorTheme.accent
    case .agreed:
      HarnessMonitorTheme.success
    case .disputed:
      HarnessMonitorTheme.danger
    case .resolved:
      HarnessMonitorTheme.ink.opacity(0.55)
    }
  }

  public var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
      Circle()
        .fill(tint)
        .frame(width: 8, height: 8)
        .padding(.top, 6)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Text(point.state.title)
            .scaledFont(.caption2.weight(.bold))
            .tracking(HarnessMonitorTheme.uppercaseTracking)
            .foregroundStyle(tint)
          Spacer()
        }
        Text(point.text)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
        if let note = point.workerNote, !note.isEmpty {
          Text(note)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCellPadding()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessMonitorAccessibility.reviewPointChip(point.pointId))
    .accessibilityLabel(Text("\(point.state.title) point: \(point.text)"))
  }
}

public struct RoundCounterPillView: View {
  public let taskID: String
  public let round: Int

  public init(taskID: String, round: Int) {
    self.taskID = taskID
    self.round = round
  }

  private var isArbitrationImminent: Bool { round >= 3 }

  public var body: some View {
    Text("Round \(round)")
      .scaledFont(.caption.weight(.semibold))
      .harnessPillPadding()
      .harnessContentPill(
        tint: isArbitrationImminent ? HarnessMonitorTheme.danger : HarnessMonitorTheme.accent
      )
      .foregroundStyle(
        isArbitrationImminent ? HarnessMonitorTheme.danger : HarnessMonitorTheme.accent
      )
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityIdentifier(HarnessMonitorAccessibility.roundCounter(taskID))
      .accessibilityLabel(
        Text(
          isArbitrationImminent
            ? "Round \(round), arbitration required"
            : "Review round \(round)"
        )
      )
  }
}

public struct ImproverTaskCardView: View {
  public let task: WorkItem

  public init(task: WorkItem) {
    self.task = task
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "wand.and.stars")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.accent)
        Text("Improver")
          .scaledFont(.caption2.weight(.bold))
          .tracking(HarnessMonitorTheme.uppercaseTracking)
          .foregroundStyle(HarnessMonitorTheme.accent)
      }
      Text(task.title)
        .scaledFont(.subheadline.weight(.semibold))
      if let context = task.context, !context.isEmpty {
        Text(context)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(3)
      }
      if let suggestion = task.suggestedFix, !suggestion.isEmpty {
        Text(suggestion)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
          .lineLimit(3)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCellPadding()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.improverTaskCard(task.taskId))
    .accessibilityLabel(Text("Improver task: \(task.title)"))
  }
}

public struct InspectorReviewStateSection: View {
  public let task: WorkItem

  public init(task: WorkItem) {
    self.task = task
  }

  private var shouldRender: Bool {
    task.awaitingReview != nil
      || task.reviewClaim != nil
      || task.reviewRound > 0
      || task.consensus != nil
      || !(task.consensus?.points.isEmpty ?? true)
  }

  public var body: some View {
    if shouldRender {
      InspectorSection(title: "Review State") {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          FlowRow(spacing: HarnessMonitorTheme.spacingXS) {
            if task.awaitingReview != nil, let awaiting = task.awaitingReview {
              AwaitingReviewBadgeView(taskID: task.taskId, awaitingReview: awaiting)
            }
            if task.reviewRound > 0 {
              RoundCounterPillView(taskID: task.taskId, round: task.reviewRound)
            }
            if task.awaitingReview != nil || task.reviewClaim != nil {
              ReviewerQuorumIndicatorView(
                taskID: task.taskId,
                claim: task.reviewClaim,
                required: task.awaitingReview?.requiredConsensus ?? 2
              )
            }
          }
          if let claim = task.reviewClaim, !claim.reviewers.isEmpty {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              ForEach(claim.reviewers, id: \.reviewerAgentId) { reviewer in
                ReviewerClaimBadgeView(taskID: task.taskId, reviewer: reviewer)
              }
            }
          }
          if let consensus = task.consensus, !consensus.points.isEmpty {
            VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
              ForEach(consensus.points) { point in
                PartialAgreementChipView(point: point)
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct FlowRow: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let maxWidth = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > maxWidth, x > 0 {
        y += rowHeight + spacing
        x = 0
        rowHeight = 0
      }
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      totalWidth = max(totalWidth, x)
    }
    return CGSize(width: totalWidth, height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let maxWidth = proposal.width ?? bounds.width
    var x: CGFloat = bounds.minX
    var y: CGFloat = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
        y += rowHeight + spacing
        x = bounds.minX
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(size)
      )
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
