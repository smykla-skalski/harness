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

  var body: some View {
    VStack(spacing: 0) {
      mainRow
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

      primaryActionGroup

    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private var primaryActionGroup: some View {
    HStack(spacing: 8) {
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

}

// `PolicyCanvasChromeBannerOverlay` and its banner rows live
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
  let workspace: TaskBoardPolicyCanvasWorkspace?
  let viewModel: PolicyCanvasViewModel
  let automationPolicyCenter: AutomationPolicyCenter
  @Binding var isAutomationPolicySheetPresented: Bool
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  var body: some View {
    let enforcement = canvasEnforcementState

    Button {
      viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    } label: {
      Label("Reformat canvas", systemImage: "arrow.clockwise")
    }
    .disabled(!viewModel.canReflowLayout)

    Button {
      isAutomationPolicySheetPresented = true
    } label: {
      Label("Automation Coverage", systemImage: "slider.horizontal.3")
    }

    if onExport != nil || onImport != nil {
      Divider()
      if let onExport {
        Button(action: onExport) {
          Label("Export Canvas\u{2026}", systemImage: "square.and.arrow.up")
        }
      }
      if let onImport {
        Button(action: onImport) {
          Label("Import Canvas\u{2026}", systemImage: "square.and.arrow.down")
        }
      }
    }

    Divider()

    PolicyCanvasToolsDisplayOptionsSection()

    Divider()

    Button {
      automationPolicyCenter.replaceCanvasPolicies(enforcement.policies)
    } label: {
      Label(enforcement.title, systemImage: enforcement.systemImage)
    }
    .disabled(!enforcement.isAvailable)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEnforceAutomationButton)
  }

  private var canvasEnforcementState: PolicyCanvasEnforcementState {
    let compilation = PolicyCanvasAutomationPolicyCompiler.compileEnforcedCanvases(
      workspace: workspace,
      activeDocument: nil
    )
    return PolicyCanvasEnforcementState(
      policies: compilation.policies,
      hasExistingPolicies: automationPolicyCenter.document.hasCanvasPolicies
    )
  }
}

private struct PolicyCanvasToolsDisplayOptionsSection: View {
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var shortcutsVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasMinimapDefaults.centeringModeKey)
  private var minimapCenteringMode = PolicyCanvasMinimapCenteringMode.defaultValue
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue
  @AppStorage(PolicyCanvasWorkflowStatusDefaults.isVisibleKey)
  private var workflowStatusVisible = PolicyCanvasWorkflowStatusDefaults.isVisibleDefault

  var body: some View {
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

    Picker("Minimap recenter", selection: $minimapCenteringMode) {
      ForEach(PolicyCanvasMinimapCenteringMode.allCases) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.inline)

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
  }
}

private struct PolicyCanvasEnforcementState {
  let policies: [AutomationPolicy]
  let hasExistingPolicies: Bool

  var isAvailable: Bool {
    !policies.isEmpty || hasExistingPolicies
  }

  var title: String {
    isClearing ? "Clear Effective Canvases" : "Sync Effective Canvases"
  }

  var systemImage: String {
    isClearing ? "xmark.shield" : "checkmark.shield"
  }

  private var isClearing: Bool {
    policies.isEmpty && hasExistingPolicies
  }
}
