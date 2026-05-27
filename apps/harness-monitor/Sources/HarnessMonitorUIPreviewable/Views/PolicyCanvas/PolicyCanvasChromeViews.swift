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
  let configureAutomationPolicies: @MainActor () -> Void
  let hasEnforcedCanvasPolicies: Bool
  let enforceCanvasPolicies: @MainActor () -> Void
  let reflowLayout: @MainActor () -> Void
  let save: @MainActor () -> Void
  let simulate: @MainActor () -> Void
  let promote: @MainActor () -> Void
  let recoverEdits: @MainActor () -> Void

  var body: some View {
    VStack(spacing: 0) {
      mainRow
      workflowStatusStrip
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

      PolicyCanvasTopBarToolsMenu(
        reflowAvailable: viewModel.canReflowLayout,
        reflowLayout: reflowLayout,
        configureAutomationPolicies: configureAutomationPolicies,
        canvasEnforcementAvailable: canvasEnforcementAvailable,
        canvasEnforcementTitle: canvasEnforcementTitle,
        canvasEnforcementSystemImage: canvasEnforcementSystemImage,
        canvasEnforcementHelp: canvasEnforcementHelp,
        enforceCanvasPolicies: enforceCanvasPolicies
      )
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 8)
  }

  private var workflowContext: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "rectangle.3.group.bubble")
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .accessibilityHidden(true)

        Picker("Canvas mode", selection: $viewModel.selectedTab) {
          ForEach(PolicyCanvasTab.allCases) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Canvas mode")
        .frame(width: 290)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasTabs)
      }

      Text(workflowDescription)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var workflowDescription: String {
    if remoteActionsEnabled {
      return "Edit the policy, run a simulation, and promote when the workflow is ready."
    }
    return remoteActionDisabledReason
  }

  private var workflowStatusStrip: some View {
    PolicyCanvasWorkflowStatusStrip(
      cards: [
        PolicyCanvasWorkflowStatusCardModel(
          id: "draft",
          title: "Draft",
          detail: viewModel.draftStatusText,
          systemImage: viewModel.documentDirty ? "pencil.circle.fill" : "checkmark.circle.fill",
          tone: draftTone
        ),
        PolicyCanvasWorkflowStatusCardModel(
          id: "validation",
          title: "Validation",
          detail: viewModel.validationStatusText,
          systemImage: validationSystemImage,
          tone: validationTone
        ),
        PolicyCanvasWorkflowStatusCardModel(
          id: "promotion",
          title: "Promotion",
          detail: promotionStatusText,
          systemImage: promotionSystemImage,
          tone: promotionTone
        ),
      ]
    )
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
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

  private var canvasEnforcementAvailable: Bool {
    !viewModel.automationPolicyCompilation.policies.isEmpty || hasEnforcedCanvasPolicies
  }

  private var isClearingCanvasPolicies: Bool {
    viewModel.automationPolicyCompilation.policies.isEmpty && hasEnforcedCanvasPolicies
  }

  private var canvasEnforcementTitle: String {
    isClearingCanvasPolicies ? "Clear Canvas" : "Enforce Canvas"
  }

  private var canvasEnforcementSystemImage: String {
    isClearingCanvasPolicies ? "xmark.shield" : "checkmark.shield"
  }

  private var canvasEnforcementHelp: String {
    isClearingCanvasPolicies
      ? "Clear enforced canvas automation policies"
      : viewModel.automationPolicyCompilation.summaryText
  }

  private var draftTone: PolicyCanvasWorkflowTone {
    if viewModel.isSavingDraft {
      return .active
    }
    if viewModel.backingDocument == nil || viewModel.documentDirty {
      return .warning
    }
    return .ready
  }

  private var validationTone: PolicyCanvasWorkflowTone {
    if viewModel.isSimulating {
      return .active
    }
    if viewModel.backingDocument == nil || viewModel.latestSimulation == nil {
      return .warning
    }
    if viewModel.documentDirty
      || viewModel.latestSimulation?.revision != viewModel.backingDocument?.revision
    {
      return .warning
    }
    if viewModel.validationErrorCount > 0 {
      return .blocked
    }
    if viewModel.validationWarningCount > 0 {
      return .warning
    }
    return .ready
  }

  private var validationSystemImage: String {
    if viewModel.isSimulating {
      return "play.circle.fill"
    }
    if viewModel.validationErrorCount > 0 {
      return "exclamationmark.triangle.fill"
    }
    if viewModel.validationWarningCount > 0 {
      return "exclamationmark.circle.fill"
    }
    return "checkmark.shield.fill"
  }

  private var promotionTone: PolicyCanvasWorkflowTone {
    if viewModel.isPromoting {
      return .active
    }
    if !remoteActionsEnabled {
      return .warning
    }
    return canPromote ? .ready : .blocked
  }

  private var promotionStatusText: String {
    if !remoteActionsEnabled {
      return remoteActionDisabledReason
    }
    return viewModel.promotionStatusText
  }

  private var promotionSystemImage: String {
    if viewModel.isPromoting {
      return "arrow.up.right.circle.fill"
    }
    return canPromote ? "checkmark.seal.fill" : "lock.circle.fill"
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

private struct PolicyCanvasTopBarToolsMenu: View {
  let reflowAvailable: Bool
  let reflowLayout: @MainActor () -> Void
  let configureAutomationPolicies: @MainActor () -> Void
  let canvasEnforcementAvailable: Bool
  let canvasEnforcementTitle: String
  let canvasEnforcementSystemImage: String
  let canvasEnforcementHelp: String
  let enforceCanvasPolicies: @MainActor () -> Void
  @Environment(\.fontScale)
  private var fontScale
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var shortcutsVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault

  var body: some View {
    Menu {
      Button(action: reflowLayout) {
        Label("Reflow layout", systemImage: "arrow.clockwise")
      }
      .disabled(!reflowAvailable)

      Button(action: configureAutomationPolicies) {
        Label("Automation Coverage", systemImage: "slider.horizontal.3")
      }

      Divider()

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

      Divider()

      Button(action: enforceCanvasPolicies) {
        Label(canvasEnforcementTitle, systemImage: canvasEnforcementSystemImage)
      }
      .disabled(!canvasEnforcementAvailable)
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasEnforceAutomationButton)
    } label: {
      Label("Policy tools", systemImage: "ellipsis.circle")
        .lineLimit(1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolsButton)
    .accessibilityLabel("Policy tools")
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .environment(
      \.harnessNativeFormControlFont,
      HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
    )
    .environment(\.harnessNativeFormControlSize, .small)
    .harnessNativeFormControl()
    .controlSize(.small)
    .help(canvasEnforcementHelp)
  }
}
