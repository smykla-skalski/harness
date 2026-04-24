import HarnessMonitorKit
import SwiftUI

public struct ArbitrationBannerView: View {
  public let task: WorkItem

  public init(task: WorkItem) {
    self.task = task
  }

  private var isArbitrated: Bool { task.arbitration != nil }

  private var symbolName: String {
    isArbitrated ? "gavel.fill" : "exclamationmark.triangle.fill"
  }

  private var tint: Color {
    isArbitrated ? HarnessMonitorTheme.success : HarnessMonitorTheme.caution
  }

  private var headline: String {
    if let outcome = task.arbitration {
      return "Arbitrated by \(outcome.arbiterAgentId) · \(outcome.verdict.title)"
    }
    return "Awaiting arbitration · round \(task.reviewRound)"
  }

  private var detail: String {
    if let outcome = task.arbitration {
      return outcome.summary
    }
    return "Reviewers exhausted the consensus rounds. Leader must arbitrate \(task.title)."
  }

  public var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: symbolName)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(headline)
          .scaledFont(.caption.weight(.semibold))
        Text(detail)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .foregroundStyle(tint)
    .background {
      Color(nsColor: .windowBackgroundColor)
        .overlay(tint.opacity(0.14))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(headline))
    .accessibilityValue(Text(detail))
    .accessibilityIdentifier(HarnessMonitorAccessibility.arbitrationBanner(task.taskId))
  }
}
