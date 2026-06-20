import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Identifies a pending go-live confirmation. `revision` is the saved revision
/// make-live will enforce; it doubles as the `.sheet(item:)` identity so editing
/// + saving (which bumps the revision) re-presents a fresh comparison.
struct PolicyCanvasGoLiveRequest: Identifiable, Equatable {
  let revision: UInt64
  var id: UInt64 { revision }
}

/// Confirmation sheet for making the draft the live, enforced policy. Loads the
/// read-only decision diff against the current live policy, blocks confirmation
/// when validation no longer passes, and on confirm hands off to the host's
/// make-live action. Follows the policy-canvas sheet convention: an injected
/// `dismiss` closure and a custom footer rather than a navigation toolbar.
struct PolicyCanvasGoLiveSheet: View {
  let viewModel: PolicyCanvasViewModel
  let liveStatus: PolicyCanvasLiveState
  let loadDiff: @MainActor () async -> TaskBoardPolicyPipelineGoLiveDiff?
  let confirm: @MainActor () -> Void
  let dismiss: @MainActor () -> Void

  @State private var diff: TaskBoardPolicyPipelineGoLiveDiff?
  @State private var isLoadingDiff = true

  private var canConfirm: Bool {
    viewModel.canMakeLive && !isLoadingDiff && diff != nil
  }

  var body: some View {
    VStack(spacing: 0) {
      header

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let reason = viewModel.makeLiveDisabledReason {
            blockingBanner(reason)
          }
          PolicyCanvasGoLiveDiffView(diff: diff, isLoading: isLoadingDiff)
        }
        .padding(16)
      }

      footer
    }
    .frame(minWidth: 480, idealWidth: 560, maxWidth: 640, minHeight: 420)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasGoLiveSheet)
    .harnessMCPElementTrackingEnabled(false)
    .task {
      diff = await loadDiff()
      isLoadingDiff = false
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("Make policy live")
          .scaledFont(.title3.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
        Spacer(minLength: 12)
        PolicyCanvasLiveStatusBadge(status: liveStatus)
      }
      Text("Review how this changes decisions versus the current live policy, then confirm.")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 16)
    .padding(.top, 16)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
  }

  private func blockingBanner(_ reason: String) -> some View {
    Label(reason, systemImage: "exclamationmark.octagon.fill")
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(PolicyCanvasWorkflowTone.blocked.tint)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        PolicyCanvasWorkflowTone.blocked.background,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(PolicyCanvasWorkflowTone.blocked.border, lineWidth: 1)
      }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Text("The live policy governs real automation work")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .lineLimit(1)

      Spacer(minLength: 16)

      Button("Cancel", action: dismiss)
        .keyboardShortcut(.cancelAction)
        .harnessActionButtonStyle(variant: .bordered)
        .controlSize(.small)

      Button("Make live") {
        confirm()
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .prominent, tint: PolicyCanvasVisualStyle.readyTint)
      .controlSize(.small)
      .disabled(!canConfirm)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasMakeLiveButton)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(PolicyCanvasVisualStyle.chromeBackground)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
  }
}
