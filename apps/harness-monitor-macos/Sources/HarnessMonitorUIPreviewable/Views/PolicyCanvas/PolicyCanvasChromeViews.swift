import HarnessMonitorKit
import Observation
import SwiftUI

struct PolicyCanvasTopBar: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  let canPromote: Bool
  /// True when there is a simulation payload to visualize. The toggle is
  /// disabled when this is false so the user doesn't get a button that
  /// does nothing.
  let simulationOverlayAvailable: Bool
  /// Resolved visibility (host's `@State` override OR auto-show on
  /// simulation tab). The button checkmark mirrors this value.
  let simulationOverlayVisible: Bool
  let toggleSimulationOverlay: @MainActor () -> Void
  let save: @MainActor () -> Void
  let simulate: @MainActor () -> Void
  let promote: @MainActor () -> Void
  let recoverEdits: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 0) {
      mainRow
      PolicyCanvasAutosaveDisabledBanner(viewModel: viewModel, retry: save)
      PolicyCanvasRecoveryBanner(
        viewModel: viewModel,
        recover: recoverEdits,
        dismiss: { viewModel.clearRecoveryBuffer() }
      )
    }
    .background(Color(red: 0.08, green: 0.09, blue: 0.12).opacity(0.98))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(Color.white.opacity(0.08))
        .frame(height: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTopBar)
  }

  private var mainRow: some View {
    HStack(spacing: 12) {
      Label("Configurable Policy Canvas", systemImage: "rectangle.3.group.bubble")
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(.white)

      Picker("Canvas mode", selection: $viewModel.selectedTab) {
        ForEach(PolicyCanvasTab.allCases) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 290)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTabs)

      Spacer(minLength: 16)

      PolicyCanvasSimulationToggleButton(
        available: simulationOverlayAvailable,
        visible: simulationOverlayVisible,
        toggle: toggleSimulationOverlay
      )

      if viewModel.hasPendingDocumentUpdate {
        Button {
          viewModel.applyPendingUpdate()
        } label: {
          Label("Remote changes available - reload?", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .orange)
        .controlSize(.small)
        .help("Apply the latest pipeline from the dashboard and discard local edits.")
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReloadButton)
      }

      PolicyCanvasActionButton(
        title: "Save",
        systemImage: "square.and.arrow.down",
        isBusy: viewModel.isSavingDraft,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSaveButton,
        action: {
          viewModel.save()
          save()
        }
      )

      PolicyCanvasActionButton(
        title: "Simulate",
        systemImage: "play.circle",
        isBusy: viewModel.isSimulating,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSimulateButton,
        action: {
          viewModel.simulate()
          simulate()
        }
      )

      VStack(alignment: .trailing, spacing: 2) {
        PolicyCanvasActionButton(
          title: "Promote",
          systemImage: "arrow.up.right.circle",
          tint: Color.green,
          isDisabled: !canPromote,
          disabledReason: viewModel.promoteDisabledReason,
          isBusy: viewModel.isPromoting,
          accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasPromoteButton,
          action: {
            viewModel.promote()
            promote()
          }
        )

        if let reason = viewModel.promoteDisabledReason {
          // White at 78% opacity reads ~5.6:1 on the top bar backdrop
          // `#14171F` — clears WCAG AA for small text without competing with
          // the action button glyph color.
          Text(reason)
            .scaledFont(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(1)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.policyCanvasPromoteDisabledReason
            )
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

// `PolicyCanvasAutosaveDisabledBanner` and `PolicyCanvasRecoveryBanner` live
// in `PolicyCanvasBanners.swift` so this file stays under the 420-line cap.

/// Topbar toggle for the simulation-result overlay. The icon flips between
/// an empty waveform and a filled waveform to mirror "off"/"on" the same
/// way the validation panel's filter chips do; disabled rendering kicks in
/// when there's no simulation to visualize so the user doesn't get a
/// button that does nothing.
private struct PolicyCanvasSimulationToggleButton: View {
  let available: Bool
  let visible: Bool
  let toggle: @MainActor () -> Void

  var body: some View {
    Button(action: toggle) {
      Label(
        visible ? "Hide simulation" : "Show simulation",
        systemImage: visible ? "waveform.path.ecg" : "waveform"
      )
      .scaledFont(.callout.weight(.semibold))
      .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: Color.cyan.opacity(0.85))
    .controlSize(.small)
    .disabled(!available)
    .help(
      available
        ? (visible ? "Hide simulation outcome badges" : "Show simulation outcome badges")
        : "Run a simulation to see outcomes"
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasSimulationToggle)
  }
}

