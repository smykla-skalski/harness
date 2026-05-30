import HarnessMonitorKit
import Observation
import SwiftUI

struct PolicyCanvasTopBar: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  let canPromote: Bool
  let remoteActionsEnabled: Bool
  let remoteActionDisabledReason: String
  /// True when there is a simulation payload to visualize. The toggle is
  /// disabled when this is false so the user doesn't get a button that
  /// does nothing.
  let simulationOverlayAvailable: Bool
  /// Resolved visibility (host's `@State` override OR auto-show on
  /// simulation tab). The button checkmark mirrors this value.
  let simulationOverlayVisible: Bool
  let toggleSimulationOverlay: @MainActor () -> Void
  let reflowLayout: @MainActor () -> Void
  let save: @MainActor () -> Void
  let simulate: @MainActor () -> Void
  let promote: @MainActor () -> Void
  let recoverEdits: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 0) {
      mainRow
      if viewModel.hasPendingDocumentUpdate {
        remoteChangesBanner
      }
      PolicyCanvasAutosaveDisabledBanner(viewModel: viewModel, retry: save)
      PolicyCanvasRecoveryBanner(
        viewModel: viewModel,
        recover: recoverEdits,
        dismiss: { viewModel.clearRecoveryBuffer() }
      )
    }
    .background(PolicyCanvasVisualStyle.chromeBackground)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTopBar)
  }

  private var mainRow: some View {
    HStack(alignment: .center, spacing: 12) {
      workflowContext

      Spacer(minLength: 16)

      PolicyCanvasSimulationToggleButton(
        available: simulationOverlayAvailable,
        visible: simulationOverlayVisible,
        toggle: toggleSimulationOverlay
      )

      PolicyCanvasActionButton(
        title: "Reformat",
        systemImage: "arrow.clockwise",
        isDisabled: !viewModel.canReflowLayout,
        disabledReason: "Add nodes before reformatting the canvas",
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasReformatButton,
        action: reflowLayout
      )

      PolicyCanvasActionButton(
        title: "Save",
        systemImage: "square.and.arrow.down",
        isDisabled: !remoteActionsEnabled,
        disabledReason: remoteActionDisabledReason,
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
        isDisabled: !remoteActionsEnabled,
        disabledReason: remoteActionDisabledReason,
        isBusy: viewModel.isSimulating,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasSimulateButton,
        action: {
          viewModel.simulate()
          simulate()
        }
      )

      PolicyCanvasActionButton(
        title: "Promote",
        systemImage: "arrow.up.right.circle",
        tint: PolicyCanvasVisualStyle.readyTint,
        isDisabled: !remoteActionsEnabled || !canPromote,
        disabledReason: remoteActionsEnabled
          ? viewModel.promoteDisabledReason
          : remoteActionDisabledReason,
        isBusy: viewModel.isPromoting,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasPromoteButton,
        action: {
          viewModel.promote()
          promote()
        }
      )

    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private var workflowContext: some View {
    Picker("Canvas mode", selection: $viewModel.selectedTab) {
      ForEach(PolicyCanvasTab.allCases) { tab in
        Text(tab.title).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel("Canvas mode")
    .frame(width: 290, alignment: .leading)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTabs)
  }

  private var remoteChangesBanner: some View {
    HStack(spacing: 10) {
      Label("Remote changes available", systemImage: "arrow.triangle.2.circlepath")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.warningTint)

      Text("Reload the latest saved policy before you keep editing.")
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)

      Button {
        viewModel.applyPendingUpdate()
      } label: {
        Label("Reload latest policy", systemImage: "arrow.clockwise")
          .scaledFont(.caption.weight(.semibold))
          .lineLimit(1)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.warningTint)
      .controlSize(.small)
      .help("Apply the latest pipeline from the dashboard and discard local edits")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasReloadButton)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.warningTint.opacity(0.76))
        .frame(width: 3)
    }
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(height: 1)
    }
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
    .harnessActionButtonStyle(variant: .bordered, tint: PolicyCanvasVisualStyle.activeTint)
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

struct PolicyCanvasToolsMenuContent: View {
  let viewModel: PolicyCanvasViewModel
  let automationPolicyCenter: AutomationPolicyCenter
  @Binding var isAutomationPolicySheetPresented: Bool
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var shortcutsVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue
  @AppStorage(PolicyCanvasWorkflowStatusDefaults.isVisibleKey)
  private var workflowStatusVisible = PolicyCanvasWorkflowStatusDefaults.isVisibleDefault

  var body: some View {
    Button {
      viewModel.reflowLayout()
    } label: {
      Label("Reformat canvas", systemImage: "arrow.clockwise")
    }
    .disabled(!viewModel.canReflowLayout)

    Button {
      isAutomationPolicySheetPresented = true
    } label: {
      Label("Automation Coverage", systemImage: "slider.horizontal.3")
    }

    Divider()

    Picker("Canvas theme", selection: $canvasThemeMode) {
      ForEach(PolicyCanvasThemeMode.allCases) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.inline)

    Button {
      minimapVisible.toggle()
    } label: {
      Label(
        minimapVisible ? "Hide minimap" : "Show minimap",
        systemImage: minimapVisible ? "eye.slash" : "eye"
      )
    }

    Button {
      edgeLegendVisible.toggle()
    } label: {
      Label(
        edgeLegendVisible ? "Hide edge legend" : "Show edge legend",
        systemImage: edgeLegendVisible ? "eye.slash" : "eye"
      )
    }

    Button {
      shortcutsVisible.toggle()
    } label: {
      Label(
        shortcutsVisible ? "Hide shortcuts reference" : "Show shortcuts reference",
        systemImage: "keyboard"
      )
    }

    Button {
      workflowStatusVisible.toggle()
    } label: {
      Label(
        workflowStatusVisible ? "Hide workflow status" : "Show workflow status",
        systemImage: workflowStatusVisible ? "eye.slash" : "eye"
      )
    }

    Divider()

    Button {
      automationPolicyCenter.replaceCanvasPolicies(viewModel.automationPolicyCompilation.policies)
    } label: {
      Label(canvasEnforcementTitle, systemImage: canvasEnforcementSystemImage)
    }
    .disabled(!canvasEnforcementAvailable)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEnforceAutomationButton)
  }

  private var canvasEnforcementAvailable: Bool {
    !viewModel.automationPolicyCompilation.policies.isEmpty
      || automationPolicyCenter.document.hasCanvasPolicies
  }

  private var isClearingCanvasPolicies: Bool {
    viewModel.automationPolicyCompilation.policies.isEmpty
      && automationPolicyCenter.document.hasCanvasPolicies
  }

  private var canvasEnforcementTitle: String {
    isClearingCanvasPolicies ? "Clear Canvas" : "Enforce Canvas"
  }

  private var canvasEnforcementSystemImage: String {
    isClearingCanvasPolicies ? "xmark.shield" : "checkmark.shield"
  }
}
