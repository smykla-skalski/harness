import HarnessMonitorPolicyCanvas
import SwiftUI

public struct SettingsPoliciesSection: View {
  public let isActive: Bool
  @Environment(\.openDashboardRoute)
  private var openDashboardRoute
  @State private var policyCenter = AutomationPolicyCenter.shared

  public init(isActive: Bool = true) {
    self.isActive = isActive
  }

  public var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Text("Dashboard > Policies is the source of truth for policy authoring.")
            .scaledFont(.body.weight(.semibold))
          Text(
            "Edit policy flow, automation rules, validation, simulation, and "
              + "promotion from one workspace. Settings now keeps only global "
              + "runtime status and canvas display preferences."
          )
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)

          Button {
            openDashboardRoute(.policyCanvas)
          } label: {
            Label(
              "Open Policy Workspace", systemImage: DashboardWindowRoute.policyCanvas.systemImage)
          }
          .harnessActionButtonStyle(variant: .prominent)
        }
      } header: {
        Text("Policy Workspace")
      } footer: {
        Text(
          "Use the workspace when you need to change rules. The canvas inspector "
            + "and automation coverage sheet are the supported editing surfaces."
        )
      }

      Section {
        Toggle(
          "Enable automation policies",
          isOn: Binding(
            get: { policyCenter.isAutomationEnabled },
            set: { policyCenter.setAutomationEnabled($0) }
          )
        )

        LabeledContent("Coverage") {
          Text(policyCenter.policySummaryText)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }

        LabeledContent("Clipboard status") {
          Text(policyCenter.clipboardRuntimeState.label)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .multilineTextAlignment(.trailing)
        }

        if let summary = policyCenter.lastClipboardEventSummary {
          LabeledContent("Last event") {
            VStack(alignment: .trailing, spacing: 2) {
              Text(summary)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
              if let date = policyCenter.lastClipboardEventAt {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                  .scaledFont(.caption2)
                  .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
              }
            }
          }
        }
      } header: {
        Text("Runtime")
      } footer: {
        Text(
          "Keep this switch for emergency stop/start control. Change policy rules "
            + "in Dashboard > Policies so validation, simulation, and enforcement "
            + "stay in one flow."
        )
      }

      recentActivitySection

      SettingsPoliciesCanvasPreferencesSection()
    }
    .settingsDetailFormStyle()
  }

  @ViewBuilder private var recentActivitySection: some View {
    Section {
      if policyCenter.recentAutomationEvents.isEmpty {
        Text("No policy activity yet")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        ForEach(Array(policyCenter.recentAutomationEvents.prefix(6))) { event in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
              Text(event.policyName ?? event.source.title)
                .scaledFont(.caption.weight(.semibold))
              Spacer(minLength: 0)
              Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .scaledFont(.caption2)
                .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
            }
            Text(event.summary)
              .scaledFont(.caption)
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(2)
          }
          .padding(.vertical, HarnessMonitorTheme.spacingXS)
        }
      }

    } header: {
      Text("Recent Activity")
    } footer: {
      Text(
        "Recent matches are shown here for awareness. Return to "
          + "Dashboard > Policies when you need to change how the project behaves."
      )
    }
  }

  private struct SettingsPoliciesCanvasPreferencesSection: View {
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
    @AppStorage(PolicyCanvasAutosaveDefaults.debounceSecondsKey)
    private var autosaveDebounceSeconds = PolicyCanvasAutosaveDefaults.defaultDebounceSeconds
    @AppStorage(PolicyCanvasWorkflowStatusDefaults.isVisibleKey)
    private var workflowStatusVisible = PolicyCanvasWorkflowStatusDefaults.isVisibleDefault

    var body: some View {
      Section {
        Picker("Canvas theme", selection: $canvasThemeMode) {
          ForEach(PolicyCanvasThemeMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsPoliciesCanvasThemePicker)
        .help(
          "Choose whether policy canvas surfaces follow the app theme or use a "
            + "canvas-only light or dark override."
        )

        Picker("Autosave", selection: $autosaveDebounceSeconds) {
          ForEach(PolicyCanvasAutosaveDefaults.presetSeconds, id: \.self) { seconds in
            Text(PolicyCanvasAutosaveDefaults.label(forSeconds: seconds)).tag(seconds)
          }
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsPoliciesAutosaveIntervalPicker)
        .help(
          "Maximum time the canvas coalesces active edits before saving to the daemon. "
            + "Off disables timed autosave; Cmd+S still saves immediately."
        )

        Toggle("Show edge legend", isOn: $edgeLegendVisible)
          .accessibilityHint(
            "Shows or hides the edge legend card in Policy Canvas windows"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesEdgeLegendToggle
          )

        Toggle("Show canvas minimap", isOn: $minimapVisible)
          .accessibilityHint(
            "Shows or hides the overview minimap in Policy Canvas windows"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesMinimapToggle
          )

        Picker("Minimap recenter", selection: $minimapCenteringMode) {
          ForEach(PolicyCanvasMinimapCenteringMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.settingsPoliciesMinimapCenteringPicker
        )
        .help(
          "Choose whether the minimap recenters when you click the viewport or only "
            + "when you use the center button."
        )

        Toggle("Show shortcuts reference", isOn: $shortcutsVisible)
          .accessibilityHint(
            "Shows or hides the shortcuts reference card in Policy Canvas windows"
          )

        Toggle("Show workflow status cards", isOn: $workflowStatusVisible)
          .accessibilityHint(
            "Shows or hides the Draft, Validation, and Promotion status cards on the canvas"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesWorkflowStatusToggle
          )
      } header: {
        Text("Canvas")
      } footer: {
        Text(
          "These controls only affect the policy canvas presentation. "
            + "They do not change the project policy model."
        )
      }
    }
  }
}
