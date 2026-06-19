import SwiftUI

/// Persistent LIVE/DRAFT anchor in the policy-canvas top bar. Takes a resolved
/// `PolicyCanvasLiveState` value (not the view model) so it only redraws when
/// the anchor itself changes, and renders a tone-coded capsule chip.
struct PolicyCanvasLiveStatusBadge: View {
  let status: PolicyCanvasLiveState

  var body: some View {
    Label {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
    } icon: {
      Image(systemName: systemImage)
        .scaledFont(.caption.weight(.bold))
    }
    .foregroundStyle(tone.tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(tone.background, in: .capsule)
    .overlay {
      Capsule().strokeBorder(tone.border, lineWidth: 1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasLiveStatusBadge)
    .accessibilityLabel(accessibilityLabel)
    .help(helpText)
  }

  private var title: String {
    switch status {
    case .noPolicy:
      return "No live policy"
    case .live(let revision):
      return "LIVE \u{00b7} rev \(revision)"
    case .draft(let liveRevision):
      return liveRevision == nil
        ? "DRAFT \u{00b7} not yet live"
        : "DRAFT \u{00b7} unpublished changes"
    }
  }

  private var systemImage: String {
    switch status {
    case .noPolicy:
      return "circle.dashed"
    case .live:
      return "checkmark.seal.fill"
    case .draft:
      return "pencil.circle.fill"
    }
  }

  private var tone: PolicyCanvasWorkflowTone {
    switch status {
    case .noPolicy:
      return .warning
    case .live:
      return .ready
    case .draft:
      return .active
    }
  }

  private var accessibilityLabel: String {
    switch status {
    case .noPolicy:
      return "Policy status: no live policy"
    case .live(let revision):
      return "Policy status: live, revision \(revision)"
    case .draft(let liveRevision):
      if let liveRevision {
        return "Policy status: draft with unpublished changes, live revision \(liveRevision)"
      }
      return "Policy status: draft, not yet live"
    }
  }

  private var helpText: String {
    switch status {
    case .noPolicy:
      return "No policy is governing real work yet"
    case .live:
      return "This canvas is the live, enforced policy"
    case .draft(let liveRevision):
      return liveRevision == nil
        ? "This draft has not been made live yet"
        : "You have unpublished edits - the live policy is an earlier revision"
    }
  }
}
