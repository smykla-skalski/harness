import SwiftUI

public struct SettingsPoliciesSection: View {
  public let isActive: Bool
  @Environment(\.openWindow)
  private var openWindow
  @AppStorage(PolicyCanvasEdgeLegendDefaults.isVisibleKey)
  private var edgeLegendVisible = PolicyCanvasEdgeLegendDefaults.isVisibleDefault
  @State private var policyCenter = AutomationPolicyCenter.shared
  @State private var newPolicySource: AutomationPolicyEventSource = .clipboard

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
        Toggle(
          "Enable automation policies",
          isOn: Binding(
            get: { policyCenter.isAutomationEnabled },
            set: { policyCenter.setAutomationEnabled($0) }
          )
        )
        Text(policyCenter.policySummaryText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } header: {
        Text("Policy Engine")
      } footer: {
        Text(
          "Policies decide which mechanisms can react to app events and which actions run after a match."
        )
      }

      clipboardPolicySection
      SettingsAutomationPolicyRulesSection(
        policyCenter: policyCenter,
        newPolicySource: $newPolicySource
      )
      SettingsAutomationPolicyEventsSection(policyCenter: policyCenter)
      mechanismPolicySection

      Section {
        Toggle("Show edge legend", isOn: $edgeLegendVisible)
          .accessibilityHint(
            "Shows or hides the edge legend card in Policy Canvas windows"
          )
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsPoliciesEdgeLegendToggle
          )
      } header: {
        Text("Policies")
      } footer: {
        Text(
          """
          Controls Policy Canvas reference chrome. When edge legend is disabled,
          the legend card is removed entirely from the canvas.
          """
        )
      }
    }
    .settingsDetailFormStyle()
  }

  private var clipboardPolicy: AutomationPolicy {
    policyCenter.clipboardPolicy
  }

  private var mechanismPolicies: [AutomationPolicy] {
    policyCenter.document.policies.filter {
      $0.eventSource != .clipboard && AutomationPolicyDocument.defaultPolicyIDs.contains($0.id)
    }
  }

  private var clipboardPolicySection: some View {
    Section {
      Toggle(
        "Monitor clipboard changes",
        isOn: Binding(
          get: { policyCenter.isClipboardMonitorEnabled },
          set: { policyCenter.setPoliciesEnabled(for: .clipboard, isEnabled: $0) }
        )
      )
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsPoliciesClipboardToggle)

      LabeledContent("Status") {
        Text(policyCenter.clipboardRuntimeState.label)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
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

      Button {
        ClipboardAutomationCommands.captureCurrentClipboard(openWindow: openWindow)
      } label: {
        Label("Capture Current Clipboard", systemImage: "clipboard")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)

      Picker(
        "Source apps",
        selection: Binding(
          get: { clipboardPolicy.match.sourceAppFilter.mode },
          set: { policyCenter.setSourceAppMode($0, for: clipboardPolicy.id) }
        )
      ) {
        ForEach(AutomationSourceAppMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }

      TextField(
        "Allowed bundle IDs",
        text: Binding(
          get: {
            clipboardPolicy.match.sourceAppFilter.allowedBundleIdentifiers
              .joined(separator: ", ")
          },
          set: {
            policyCenter.setAllowedSourceAppIdentifiers([$0], for: clipboardPolicy.id)
          }
        ),
        prompt: Text("com.example.chat, com.example.browser")
      )
      .textFieldStyle(.roundedBorder)
      .disabled(clipboardPolicy.match.sourceAppFilter.mode != .allowedOnly)

      TextField(
        "Denied bundle IDs",
        text: Binding(
          get: {
            clipboardPolicy.match.sourceAppFilter.deniedBundleIdentifiers
              .joined(separator: ", ")
          },
          set: {
            policyCenter.setDeniedSourceAppIdentifiers([$0], for: clipboardPolicy.id)
          }
        ),
        prompt: Text("com.apple.keychainaccess")
      )
      .textFieldStyle(.roundedBorder)

      Divider()

      Toggle(
        AutomationPolicyPreprocessor.skipSensitiveMarkers.title,
        isOn: Binding(
          get: { clipboardPolicy.hasPreprocessor(.skipSensitiveMarkers) },
          set: {
            policyCenter.setPreprocessor(
              .skipSensitiveMarkers,
              isEnabled: $0,
              for: clipboardPolicy.id
            )
          }
        )
      )

      ForEach(AutomationPolicyAction.allCases) { action in
        Toggle(
          action.title,
          isOn: Binding(
            get: { clipboardPolicy.hasAction(action) },
            set: { policyCenter.setAction(action, isEnabled: $0, for: clipboardPolicy.id) }
          )
        )
      }
    } header: {
      Text("Clipboard")
    } footer: {
      Text(
        """
        The monitor polls NSPasteboard.general.changeCount and uses pasteboard privacy detection \
        before any policy action reads contents. It does not install global keyboard hooks.
        """
      )
    }
  }

  private var mechanismPolicySection: some View {
    Section {
      ForEach(mechanismPolicies) { policy in
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Toggle(
            policy.name,
            isOn: Binding(
              get: { policyCenter.policy(id: policy.id)?.isEnabled ?? policy.isEnabled },
              set: { policyCenter.setPolicyEnabled(policy.id, isEnabled: $0) }
            )
          )
          Text(policy.eventSource.detail)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(policy.actions.map(\.title).joined(separator: " · "))
            .scaledFont(.caption2)
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        }
        .padding(.vertical, HarnessMonitorTheme.spacingXS)
      }
    } header: {
      Text("Mechanisms")
    } footer: {
      Text(
        """
        Manual OCR mechanisms stay user-originated, but their scan, feedback, and \
        persistence actions are still represented as policies.
        """
      )
    }
  }
}
