import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import Observation
import SwiftUI

struct PolicyCanvasTopBar: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  /// Resolved persistent LIVE/DRAFT anchor rendered in the leading slot.
  let liveStatus: PolicyCanvasLiveState
  let canMakeLive: Bool
  let remoteActionsEnabled: Bool
  let remoteActionDisabledReason: String
  let reflowLayout: @MainActor () -> Void
  let makeLive: @MainActor () -> Void

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
      PolicyCanvasLiveStatusBadge(status: liveStatus)

      Spacer(minLength: 16)

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
        title: "Make live",
        systemImage: "checkmark.seal",
        variant: .prominent,
        tint: PolicyCanvasVisualStyle.readyTint,
        isDisabled: !remoteActionsEnabled || !canMakeLive,
        disabledReason: remoteActionsEnabled
          ? viewModel.makeLiveDisabledReason
          : remoteActionDisabledReason,
        isBusy: viewModel.isMakingLive,
        accessibilityIdentifier: HarnessMonitorAccessibility.policyCanvasMakeLiveButton,
        action: makeLive
      )
    }
  }

}

// `PolicyCanvasChromeBannerOverlay` and its banner rows live
// in `PolicyCanvasBanners.swift` so this file stays under the 420-line cap.

public struct PolicyCanvasToolsMenuContent: View {
  let viewModel: PolicyCanvasViewModel
  @Binding var isAutomationPolicySheetPresented: Bool
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  public init(
    viewModel: PolicyCanvasViewModel,
    isAutomationPolicySheetPresented: Binding<Bool>,
    onExport: (@MainActor () -> Void)? = nil,
    onImport: (@MainActor () -> Void)? = nil
  ) {
    self.viewModel = viewModel
    _isAutomationPolicySheetPresented = isAutomationPolicySheetPresented
    self.onExport = onExport
    self.onImport = onImport
  }

  public var body: some View {
    Button {
      viewModel.requestAtomicReflow(preserveManualAnchors: false, force: true)
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
  }
}

private struct PolicyCanvasToolsDisplayOptionsSection: View {
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var shortcutsVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasZoomControlsDefaults.isVisibleKey)
  private var zoomControlsVisible = PolicyCanvasZoomControlsDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasMinimapDefaults.centeringModeKey)
  private var minimapCenteringMode = PolicyCanvasMinimapCenteringMode.defaultValue
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue

  var body: some View {
    Menu("Canvas theme") {
      ForEach(PolicyCanvasThemeMode.allCases) { mode in
        Button {
          canvasThemeMode = mode
        } label: {
          themeMenuLabel(for: mode)
        }
      }
    }
    .accessibilityLabel("Canvas theme")
    .accessibilityValue(canvasThemeMode.label)

    Button {
      zoomControlsVisible.toggle()
    } label: {
      Label(
        zoomControlsVisible ? "Hide zoom controls" : "Show zoom controls",
        systemImage: zoomControlsVisible ? "eye.slash" : "eye"
      )
    }

    Button {
      minimapVisible.toggle()
    } label: {
      Label(
        minimapVisible ? "Hide minimap" : "Show minimap",
        systemImage: minimapVisible ? "eye.slash" : "eye"
      )
    }

    Menu("Minimap recenter") {
      ForEach(PolicyCanvasMinimapCenteringMode.allCases) { mode in
        Button {
          minimapCenteringMode = mode
        } label: {
          minimapCenteringMenuLabel(for: mode)
        }
      }
    }
    .accessibilityLabel("Minimap recenter")
    .accessibilityValue(minimapCenteringMode.label)

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
  }

  @ViewBuilder
  private func themeMenuLabel(for mode: PolicyCanvasThemeMode) -> some View {
    if canvasThemeMode == mode {
      Label(mode.label, systemImage: "checkmark")
    } else {
      Text(mode.label)
    }
  }

  @ViewBuilder
  private func minimapCenteringMenuLabel(for mode: PolicyCanvasMinimapCenteringMode) -> some View {
    if minimapCenteringMode == mode {
      Label(mode.label, systemImage: "checkmark")
    } else {
      Text(mode.label)
    }
  }
}
