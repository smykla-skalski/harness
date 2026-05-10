import HarnessMonitorKit
import SwiftUI

struct OpenRecentStartPanelLayout: Layout {
  let topInset: CGFloat
  let bottomInset: CGFloat
  let headerSpacing: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    let width = proposal.width ?? 0
    let fittedProposal = ProposedViewSize(width: width > 0 ? width : nil, height: nil)
    let headerSize = measuredSize(for: 0, subviews: subviews, proposal: fittedProposal)
    let contentSize = measuredSize(for: 1, subviews: subviews, proposal: fittedProposal)
    let naturalHeight =
      topInset + headerSize.height + headerSpacing + contentSize.height + bottomInset
    return CGSize(
      width: width > 0 ? width : max(headerSize.width, contentSize.width),
      height: proposal.height ?? naturalHeight
    )
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    let fittedProposal = ProposedViewSize(width: bounds.width, height: nil)
    let headerSize = measuredSize(for: 0, subviews: subviews, proposal: fittedProposal)
    let contentSize = measuredSize(for: 1, subviews: subviews, proposal: fittedProposal)
    let contentAreaTop = bounds.minY + topInset
    let contentAreaHeight = max(bounds.height - topInset - bottomInset, contentSize.height)
    let contentTop = contentAreaTop + max((contentAreaHeight - contentSize.height) / 2, 0)
    let headerTop = max(bounds.minY + topInset, contentTop - headerSpacing - headerSize.height)
    let placementProposal = ProposedViewSize(width: bounds.width, height: nil)

    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: headerTop),
      anchor: .topLeading,
      proposal: placementProposal
    )
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: contentTop),
      anchor: .topLeading,
      proposal: placementProposal
    )
  }

  private func measuredSize(
    for index: Int,
    subviews: Subviews,
    proposal: ProposedViewSize
  ) -> CGSize {
    guard subviews.indices.contains(index) else {
      return .zero
    }
    return subviews[index].sizeThatFits(proposal)
  }
}

struct OpenRecentShortcutLabel: View {
  let shortcut: String

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(shortcut.enumerated()), id: \.offset) { _, character in
        Text(String(character))
          .scaledFont(.caption.monospaced())
      }
    }
    .foregroundStyle(.tertiary)
    .accessibilityLabel(shortcut)
  }
}

func sessionStatusSymbol(_ status: SessionStatus) -> String {
  switch status {
  case .active: "play.circle"
  case .awaitingLeader: "person.crop.circle.badge.clock"
  case .leaderlessDegraded: "exclamationmark.triangle"
  case .paused: "pause.circle"
  case .ended: "checkmark.circle"
  }
}

enum OpenRecentCloseAfterPickMotionPolicy {
  static let animatedDismissDuration: Double = 0.16

  static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: animatedDismissDuration)
  }

  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .identity : .opacity
  }

  static func dismissDelay(reduceMotion: Bool) -> Duration {
    reduceMotion ? .zero : .milliseconds(Int(animatedDismissDuration * 1000))
  }
}

struct OpenRecentProjectGroup: Identifiable {
  let id: String
  let projectName: String
  let sessions: [OpenRecentSessionItem]

  static func groups(
    from sessions: [SessionSummary],
    bookmarkedSessionIDs: Set<String>
  ) -> [Self] {
    let grouped = Dictionary(grouping: sessions) { $0.projectId }
    return grouped.values.map { projectSessions in
      let sortedSessions = projectSessions.map {
        OpenRecentSessionItem(
          session: $0,
          isBookmarked: bookmarkedSessionIDs.contains($0.sessionId)
        )
      }
      let first = projectSessions[0]
      return Self(
        id: first.projectId,
        projectName: first.projectName,
        sessions: sortedSessions
      )
    }
    .sorted { $0.projectName.localizedCaseInsensitiveCompare($1.projectName) == .orderedAscending }
  }
}

struct OpenRecentSessionItem: Identifiable {
  let session: SessionSummary
  let isBookmarked: Bool

  var id: String { session.sessionId }

  var stateText: String {
    if session.externalOrigin != nil {
      return "Attached"
    }
    if session.adoptedAt != nil {
      return "Adopted"
    }
    return session.status.title
  }
}
