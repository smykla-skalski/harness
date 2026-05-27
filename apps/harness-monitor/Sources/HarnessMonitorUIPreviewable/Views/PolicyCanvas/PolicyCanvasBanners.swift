import SwiftUI

/// Sticky affordance the chrome shows when consecutive autosave failures cross
/// the ceiling and the subsystem flips to `.disabled`. Click to retry runs a
/// manual save on the same path as the toolbar Save button; on success the
/// view-model clears the failure counter and the affordance vanishes.
struct PolicyCanvasAutosaveDisabledBanner: View {
  let viewModel: PolicyCanvasViewModel
  let retry: @MainActor () -> Void

  var body: some View {
    if case .disabled(let reason) = viewModel.lastAutosaveOutcome {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(PolicyCanvasVisualStyle.warningTint)
        Text(reason)
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)
        Spacer(minLength: 8)
        Button {
          retry()
        } label: {
          Label("Save now", systemImage: "arrow.clockwise")
            .scaledFont(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.warningTint)
        .controlSize(.small)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasAutosaveDisabledRetryButton
        )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(PolicyCanvasVisualStyle.panelBackground)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(PolicyCanvasVisualStyle.warningTint.opacity(0.76))
          .frame(width: 3)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasAutosaveDisabledAffordance
      )
    }
  }
}

/// Recovery banner shown after a daemon reject when the user typed during the
/// round-trip. The reject path captures those edits into a buffer the user can
/// restore here before they hit Save again. Dismiss drops the buffer; Recover
/// applies it (and marks dirty so the next save attempt covers the recovered
/// state).
struct PolicyCanvasRecoveryBanner: View {
  let viewModel: PolicyCanvasViewModel
  let recover: @MainActor () -> Void
  let dismiss: @MainActor () -> Void

  var body: some View {
    if viewModel.hasRecoverableEdits {
      HStack(spacing: 8) {
        Image(systemName: "tray.and.arrow.up")
          .foregroundStyle(PolicyCanvasVisualStyle.activeTint)
        Text("Unsaved edits captured before reject")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          .lineLimit(1)
        Spacer(minLength: 8)
        Button {
          recover()
        } label: {
          Label("Recover", systemImage: "arrow.uturn.backward")
            .scaledFont(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.activeTint)
        .controlSize(.small)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasRecoveryButton
        )
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .scaledFont(.caption.weight(.semibold))
        }
        .harnessActionButtonStyle(variant: .borderless)
        .controlSize(.small)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasRecoveryDismissButton
        )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(PolicyCanvasVisualStyle.panelBackground)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(PolicyCanvasVisualStyle.activeTint.opacity(0.76))
          .frame(width: 3)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasRecoveryAffordance
      )
    }
  }
}
