import SwiftUI

struct SettingsAutomationPolicyRulesSection: View {
  let policyCenter: AutomationPolicyCenter
  @Binding var newPolicySource: AutomationPolicyEventSource

  var body: some View {
    Section {
      addRuleRow
      ForEach(policyCenter.document.policies) { policy in
        SettingsAutomationPolicyRuleEditor(
          policyID: policy.id,
          policyCenter: policyCenter
        )
      }
    } header: {
      Text("Rules")
    } footer: {
      Text(
        """
        Rules are evaluated by source and priority. The first enabled rule whose \
        match passes runs its configured actions.
        """
      )
    }
  }

  private var addRuleRow: some View {
    HStack {
      Picker("New rule source", selection: $newPolicySource) {
        ForEach(AutomationPolicyEventSource.allCases) { source in
          Text(source.title).tag(source)
        }
      }
      Spacer()
      Button {
        policyCenter.createPolicy(for: newPolicySource)
      } label: {
        Label("Add Rule", systemImage: "plus")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
    }
  }
}

private struct SettingsAutomationPolicyRuleEditor: View {
  let policyID: String
  let policyCenter: AutomationPolicyCenter

  private var policy: AutomationPolicy? {
    policyCenter.policy(id: policyID)
  }

  private var canDelete: Bool {
    !AutomationPolicyDocument.defaultPolicyIDs.contains(policyID)
  }

  var body: some View {
    if let policy {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
          identityFields(policy)
          contentKinds(policy)
          preprocessors(policy)
          actions(policy)
          postprocessors(policy)
          if policy.eventSource == .clipboard {
            sourceApplicationFilters(policy)
          }
          if canDelete {
            deleteButton
          }
        }
        .padding(.vertical, HarnessMonitorTheme.spacingSM)
      } label: {
        SettingsAutomationPolicyRuleLabel(policy: policy)
      }
    }
  }

  private func identityFields(_ policy: AutomationPolicy) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { self.policy?.isEnabled ?? policy.isEnabled },
          set: { policyCenter.setPolicyEnabled(policyID, isEnabled: $0) }
        )
      )

      TextField(
        "Rule name",
        text: Binding(
          get: { self.policy?.name ?? policy.name },
          set: { policyCenter.setPolicyName($0, for: policyID) }
        )
      )
      .textFieldStyle(.roundedBorder)

      Picker(
        "Source",
        selection: Binding(
          get: { self.policy?.eventSource ?? policy.eventSource },
          set: { policyCenter.setPolicyEventSource($0, for: policyID) }
        )
      ) {
        ForEach(AutomationPolicyEventSource.allCases) { source in
          Text(source.title).tag(source)
        }
      }
      .disabled(!canDelete)

      Stepper(
        value: Binding(
          get: { self.policy?.priority ?? policy.priority },
          set: { policyCenter.setPolicyPriority($0, for: policyID) }
        ),
        in: 0...999
      ) {
        Text("Priority \(self.policy?.priority ?? policy.priority)")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
  }

  private func contentKinds(_ policy: AutomationPolicy) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Content")
        .scaledFont(.caption.weight(.semibold))
      ForEach(AutomationClipboardContentKind.allCases, id: \.self) { kind in
        Toggle(
          kind.title,
          isOn: Binding(
            get: { self.policy?.match.contentKinds.contains(kind) ?? false },
            set: { policyCenter.setContentKind(kind, isEnabled: $0, for: policyID) }
          )
        )
      }
    }
  }

  private func preprocessors(_ policy: AutomationPolicy) -> some View {
    toggleGroup(
      title: "Preprocessors",
      values: AutomationPolicyPreprocessor.allCases,
      contains: { policy.hasPreprocessor($0) },
      set: { policyCenter.setPreprocessor($0, isEnabled: $1, for: policyID) }
    )
  }

  private func actions(_ policy: AutomationPolicy) -> some View {
    toggleGroup(
      title: "Actions",
      values: AutomationPolicyAction.allCases,
      contains: { policy.hasAction($0) },
      set: { policyCenter.setAction($0, isEnabled: $1, for: policyID) }
    )
  }

  private func postprocessors(_ policy: AutomationPolicy) -> some View {
    toggleGroup(
      title: "Postprocessors",
      values: AutomationPolicyPostprocessor.allCases,
      contains: { policy.postprocessors.contains($0) },
      set: { policyCenter.setPostprocessor($0, isEnabled: $1, for: policyID) }
    )
  }

  private func toggleGroup<Value: Identifiable & CaseIterable & Equatable>(
    title: String,
    values: Value.AllCases,
    contains: @escaping (Value) -> Bool,
    set: @escaping (Value, Bool) -> Void
  ) -> some View where Value.AllCases: RandomAccessCollection, Value: SettingsPolicyTitledValue {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
      ForEach(values) { value in
        Toggle(
          value.title,
          isOn: Binding(get: { contains(value) }, set: { set(value, $0) })
        )
      }
    }
  }

  private func sourceApplicationFilters(_ policy: AutomationPolicy) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Picker(
        "Source apps",
        selection: Binding(
          get: { self.policy?.match.sourceAppFilter.mode ?? policy.match.sourceAppFilter.mode },
          set: { policyCenter.setSourceAppMode($0, for: policyID) }
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
            self.policy?.match.sourceAppFilter.allowedBundleIdentifiers
              .joined(separator: ", ") ?? ""
          },
          set: { policyCenter.setAllowedSourceAppIdentifiers([$0], for: policyID) }
        )
      )
      .textFieldStyle(.roundedBorder)
      TextField(
        "Denied bundle IDs",
        text: Binding(
          get: {
            self.policy?.match.sourceAppFilter.deniedBundleIdentifiers
              .joined(separator: ", ") ?? ""
          },
          set: { policyCenter.setDeniedSourceAppIdentifiers([$0], for: policyID) }
        )
      )
      .textFieldStyle(.roundedBorder)
    }
  }

  private var deleteButton: some View {
    Button(role: .destructive) {
      policyCenter.deletePolicy(policyID)
    } label: {
      Label("Delete Rule", systemImage: "trash")
    }
    .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
  }
}

private struct SettingsAutomationPolicyRuleLabel: View {
  let policy: AutomationPolicy

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(policy.name)
          .lineLimit(1)
        Text(ruleDetailText)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
      }
      Spacer()
      Text(policy.isEnabled ? "On" : "Off")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(policy.isEnabled ? HarnessMonitorTheme.success : .secondary)
    }
  }

  private var ruleDetailText: String {
    let contentKinds = policy.match.contentKinds.map(\.title).sorted().joined(separator: ", ")
    return "\(policy.eventSource.title) · \(contentKinds)"
  }
}

private protocol SettingsPolicyTitledValue {
  var title: String { get }
}

extension AutomationPolicyPreprocessor: SettingsPolicyTitledValue {}
extension AutomationPolicyAction: SettingsPolicyTitledValue {}
extension AutomationPolicyPostprocessor: SettingsPolicyTitledValue {}
