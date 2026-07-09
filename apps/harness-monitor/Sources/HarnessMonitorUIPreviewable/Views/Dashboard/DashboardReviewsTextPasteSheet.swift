import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

struct DashboardReviewsPastedTextReviewSheet: View {
  let state: DashboardReviewsPastedTextReviewSheetState
  let onApprove: ([ReviewItem]) -> Void
  let onAuto: ([ReviewItem]) -> Void
  let onSelect: (ReviewItem) -> Void
  let onCopy: (String) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @FocusState private var focusedControl: FocusedControl?

  private enum FocusedControl: Hashable {
    case approve
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          summary
          ForEach(state.items) { item in
            itemCard(item)
          }
          ForEach(state.ambiguousRows) { row in
            extractionIssueCard(row, title: "Ambiguous pull request")
          }
          ForEach(state.missingRows) { row in
            extractionIssueCard(row, title: "Pull request not found")
          }
          ForEach(state.missingReferences) { reference in
            missingCard(reference)
          }
        }
        .padding(HarnessMonitorTheme.spacingXL)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(minWidth: 760, idealWidth: 880, minHeight: 560, idealHeight: 700)
    .defaultFocus($focusedControl, .approve)
    .task(id: state.id) {
      await Task.yield()
      focusedControl = state.eligibleItems.isEmpty ? nil : .approve
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Extracted Pull Requests")
          .scaledFont(.headline.weight(.semibold))
        Text(state.policyName)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXL)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
  }

  private var summary: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      metric("Found", value: "\(state.foundCount)", image: "link")
      metric("Loaded", value: "\(state.items.count)", image: "doc.text.magnifyingglass")
      metric("Copied", value: "\(state.copiedCount)", image: "doc.on.clipboard")
      if state.allowsApprovalActions {
        metric("Can approve", value: "\(state.eligibleItems.count)", image: "checkmark.seal")
      }
    }
  }

  private func metric(_ title: String, value: String, image: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: image)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .scaledFont(.title3.weight(.semibold))
        .monospacedDigit()
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.ink.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.5), lineWidth: 1)
    }
  }

  private func itemCard(_ item: ReviewItem) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title)
            .scaledFont(.body.weight(.semibold))
            .lineLimit(2)
          Text("\(item.repository) #\(item.number) · \(item.pastedReviewSubtitle)")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        DashboardReviewStatusPill(
          label: item.state.pastedReviewTitle,
          tint: stateTint(item),
          isQuiet: false
        )
      }

      if let target = previewTarget(for: item), !target.eligible, let reason = target.reason {
        Label(reason, systemImage: "exclamationmark.triangle")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.caution)
      }

      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          onSelect(item)
        } label: {
          Label("Select in Reviews", systemImage: "sidebar.right")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)

        if let url = URL(string: item.url) {
          Link(destination: url) {
            Label("Open GitHub", systemImage: "arrow.up.forward.square")
          }
          .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        }

        if state.allowsApprovalActions {
          Button {
            onApprove([item])
            dismiss()
          } label: {
            Label(
              state.dryRun ? "Dry Run" : "Approve",
              systemImage: state.dryRun ? "eye" : "checkmark.seal"
            )
          }
          .disabled(!item.canAttemptManualApproval)
          .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.ink.opacity(0.05),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(HarnessMonitorTheme.controlBorder.opacity(0.5), lineWidth: 1)
    }
  }

  private func missingCard(_ reference: GitHubPullRequestReference) -> some View {
    Label(
      "\(reference.displayText) was not found in the current Reviews data",
      systemImage: "questionmark.circle"
    )
    .scaledFont(.caption.weight(.medium))
    .foregroundStyle(HarnessMonitorTheme.caution)
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.caution.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }

  private func extractionIssueCard(
    _ row: ReviewPullRequestExtractionResolvedRow,
    title: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("\(title): \(row.row.reference.displayText)", systemImage: "questionmark.circle")
        .scaledFont(.caption.weight(.medium))
      if !row.ambiguousItems.isEmpty {
        Text(row.ambiguousItems.map { "\($0.repository)#\($0.number)" }.joined(separator: ", "))
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      if !row.row.titleText.isEmpty {
        Text(row.row.titleText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
    }
    .foregroundStyle(HarnessMonitorTheme.caution)
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.caution.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }

  private var footer: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Spacer()
      if !state.outputText.isEmpty {
        Button {
          onCopy(state.outputText)
        } label: {
          Label("Copy List", systemImage: "doc.on.clipboard")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      }
      if state.allowsApprovalActions && state.offersAutoPolicy {
        Button {
          onAuto(state.items)
          dismiss()
        } label: {
          Label("Start Auto Policy", systemImage: "bolt")
        }
        .disabled(state.items.isEmpty)
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      }
      if state.allowsApprovalActions {
        Button {
          onApprove(state.eligibleItems)
          dismiss()
        } label: {
          Label(
            state.approveButtonTitle,
            systemImage: state.dryRun ? "eye" : "checkmark.seal.fill"
          )
        }
        .disabled(state.eligibleItems.isEmpty)
        .keyboardShortcut(.defaultAction)
        .focused($focusedControl, equals: .approve)
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXL)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
  }

  private func previewTarget(for item: ReviewItem) -> ReviewActionPreviewTarget? {
    state.approvalTargetByPullRequestID[item.pullRequestID]
  }

  private func stateTint(_ item: ReviewItem) -> Color {
    switch item.state {
    case .open: HarnessMonitorTheme.success
    case .closed, .merged: HarnessMonitorTheme.secondaryInk
    case .unknown: HarnessMonitorTheme.caution
    }
  }
}

typealias DashboardReviewsExtractedPullRequestsSheet = DashboardReviewsPastedTextReviewSheet
