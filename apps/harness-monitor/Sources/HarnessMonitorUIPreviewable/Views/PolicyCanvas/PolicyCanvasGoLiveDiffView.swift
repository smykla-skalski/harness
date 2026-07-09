import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

/// One changed go-live decision: how a scenario resolves under the live policy
/// versus the draft about to be made live. `liveVerdict` is nil only when the
/// scenario had no live decision (which the no-live-policy state handles before
/// rows render). A value-type projection so the diff view never holds the wire.
struct PolicyCanvasGoLiveDiffRowModel: Identifiable, Equatable {
  let id: String
  let actionTitle: String
  let scenarioName: String
  let liveVerdict: PolicyCanvasDecisionVerdict?
  let draftVerdict: PolicyCanvasDecisionVerdict

  init(entry: PolicyPipelineGoLiveDiffEntry) {
    self.id = "\(entry.scenarioId).\(entry.action.rawValue)"
    self.actionTitle = entry.action.policyCanvasTitle
    self.scenarioName = entry.scenarioName
    self.liveVerdict = entry.liveDecision.map(PolicyCanvasDecisionVerdict.init(decision:))
    self.draftVerdict = PolicyCanvasDecisionVerdict(decision: entry.draftDecision)
  }
}

/// The go-live decision diff: per-scenario live -> draft verdicts for the
/// decisions that change when the draft is made live. Renders loading, load
/// failure, the no-live-policy first-publish state, the parity (nothing-changes)
/// state, and the changed-rows list. Driven by a resolved `PolicyPipelineGoLiveDiff`
/// so it only redraws when the comparison itself changes.
struct PolicyCanvasGoLiveDiffView: View {
  let diff: PolicyPipelineGoLiveDiff?
  let isLoading: Bool

  private var changedRows: [PolicyCanvasGoLiveDiffRowModel] {
    guard let diff else {
      return []
    }
    return diff.diffs.filter(\.changed).map(PolicyCanvasGoLiveDiffRowModel.init(entry:))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if isLoading {
        loadingState
      } else if let diff {
        content(for: diff)
      } else {
        message(
          icon: "exclamationmark.triangle",
          tone: .warning,
          title: "Comparison unavailable",
          subtitle: "Resolve the comparison before making the draft live."
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGoLiveDiff)
  }

  @ViewBuilder
  private func content(for diff: PolicyPipelineGoLiveDiff) -> some View {
    if !diff.hasLivePolicy {
      message(
        icon: "sparkles",
        tone: .active,
        title: "No policy is live yet",
        subtitle: "Making this draft live starts enforcing it for the first time."
      )
    } else if changedRows.isEmpty {
      message(
        icon: "equal.circle",
        tone: .ready,
        title: "No decisions change",
        subtitle: "The live policy already resolves every scenario the same way."
      )
    } else {
      changedList(diff: diff)
    }
  }

  private func changedList(diff: PolicyPipelineGoLiveDiff) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(changedSummary(diff: diff))
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)

      ScrollView {
        VStack(spacing: 6) {
          ForEach(changedRows) { row in
            PolicyCanvasGoLiveDiffRow(model: row)
          }
        }
      }
      .frame(maxHeight: min(CGFloat(changedRows.count) * 54, 280))
    }
  }

  private func changedSummary(diff: PolicyPipelineGoLiveDiff) -> String {
    let changed = changedRows.count
    let total = diff.diffs.count
    let unchanged = max(total - changed, 0)
    let lead = changed == 1 ? "1 decision changes" : "\(changed) decisions change"
    return unchanged == 0 ? lead : "\(lead) \u{00b7} \(unchanged) unchanged"
  }

  private var loadingState: some View {
    HStack(spacing: 8) {
      HarnessMonitorSpinner(size: 14, tint: PolicyCanvasVisualStyle.secondaryText)
      Text("Comparing against the live policy\u{2026}")
        .scaledFont(.callout)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 12)
  }

  private func message(
    icon: String,
    tone: PolicyCanvasWorkflowTone,
    title: String,
    subtitle: String
  ) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .scaledFont(.title3)
        .foregroundStyle(tone.tint)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        Text(subtitle)
          .scaledFont(.caption)
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(tone.border, lineWidth: 1)
    }
  }
}
