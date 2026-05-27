import SwiftUI

public struct SettingsPoliciesSection: View {
  public let isActive: Bool
  @Environment(\.openDashboardRoute)
  private var openDashboardRoute
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasShortcutsDefaults.isVisibleKey)
  private var shortcutsVisible = PolicyCanvasShortcutsDefaults.isVisibleDefault
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
            """
            Edit policy flow, automation rules, validation, simulation, and promotion from one workspace. Settings now keeps only global runtime status and canvas display preferences.
            """
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
          "Use the workspace when you need to change rules. The canvas inspector and automation coverage sheet are the supported editing surfaces."
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
          "Keep this switch for emergency stop/start control. Change policy rules in Dashboard > Policies so validation, simulation, and enforcement stay in one flow."
        )
      }

      recentActivitySection

      Section {
        Toggle("Show edge legend", isOn: $edgeLegendVisible)
          .accessibilityHint(
            "Shows or hides the edge legend card in Policy Canvas windows"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesEdgeLegendToggle
          )

        Toggle("Show shortcuts reference", isOn: $shortcutsVisible)
          .accessibilityHint(
            "Shows or hides the shortcuts reference card in Policy Canvas windows"
          )
      } header: {
        Text("Canvas")
      } footer: {
        Text(
          """
          These switches only control reference chrome in the policy canvas. They do not change the project policy model.
          """
        )
      }
    }
    .settingsDetailFormStyle()
  }

  @ViewBuilder
  private var recentActivitySection: some View {
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
        "Recent matches are shown here for awareness. Return to Dashboard > Policies when you need to change how the project behaves."
      )
    }
  }
}
