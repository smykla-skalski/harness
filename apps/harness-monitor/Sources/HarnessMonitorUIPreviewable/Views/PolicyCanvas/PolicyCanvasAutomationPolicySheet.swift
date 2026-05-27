import SwiftUI

struct PolicyCanvasAutomationPolicySheet: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.dismiss)
  private var dismiss
  @State private var policyCenter = AutomationPolicyCenter.shared

  private var compilation: PolicyCanvasAutomationPolicyCompilation {
    viewModel.automationPolicyCompilation
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
          sourceOfTruthCallout
          summaryCards
          compiledPoliciesSection
          runtimeSection
          recentActivitySection
        }
        .padding(HarnessMonitorTheme.spacingXL)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 760, idealWidth: 900, minHeight: 680, idealHeight: 760)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Automation Coverage")
          .scaledFont(.headline.weight(.semibold))
        Text("Review the runtime rules compiled from the current canvas before you enforce them")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingXL)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
  }

  private var sourceOfTruthCallout: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(
        "Dashboard > Policies is the source of truth",
        systemImage: DashboardWindowRoute.policyCanvas.systemImage
      )
      .scaledFont(.body.weight(.semibold))
      Text(
        """
        Edit source nodes, filters, actions, and validation directly on the canvas. This sheet \
        is a live overview of what the current draft will enforce once you save, simulate, and \
        promote it.
        """
      )
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      HarnessMonitorTheme.accent.opacity(0.10),
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(HarnessMonitorTheme.accent.opacity(0.22), lineWidth: 1)
    }
  }

  private var summaryCards: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      summaryCard(
        title: "Compiled Rules",
        value: compilation.summaryText,
        systemImage: "point.3.connected.trianglepath.dotted",
        tint: HarnessMonitorTheme.accent
      )
      summaryCard(
        title: "Engine",
        value: policyCenter.isAutomationEnabled ? "Enabled" : "Disabled",
        systemImage: policyCenter.isAutomationEnabled
          ? "checkmark.shield.fill" : "pause.circle.fill",
        tint: policyCenter.isAutomationEnabled ? .green : .orange
      )
      summaryCard(
        title: "Clipboard",
        value: policyCenter.clipboardRuntimeState.label,
        systemImage: "clipboard",
        tint: .cyan
      )
    }
  }

  private func summaryCard(
    title: String,
    value: String,
    systemImage: String,
    tint: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(tint)
      Text(value)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PolicyCanvasVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
    }
  }

  @ViewBuilder private var compiledPoliciesSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text("Compiled from the canvas")
        .scaledFont(.headline.weight(.semibold))

      if !compilation.diagnostics.isEmpty {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(compilation.diagnostics) { diagnostic in
            Label(diagnostic.message, systemImage: "exclamationmark.triangle.fill")
              .scaledFont(.caption.weight(.medium))
              .foregroundStyle(PolicyCanvasVisualStyle.warningTint)
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          PolicyCanvasVisualStyle.warningTint.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
      } else if compilation.policies.isEmpty {
        ContentUnavailableView(
          "No automation rules compiled yet",
          systemImage: "slider.horizontal.3",
          description: Text(
            """
            Add and connect a source node in the canvas to define how clipboard, paste, drop, \
            file picker, or screenshot policies should behave.
            """
          )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, HarnessMonitorTheme.spacingLG)
      } else {
        ForEach(compilation.policies) { policy in
          automationPolicyCard(policy)
        }
      }
    }
  }

  private func automationPolicyCard(_ policy: AutomationPolicy) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
        VStack(alignment: .leading, spacing: 2) {
          Text(policy.name)
            .scaledFont(.body.weight(.semibold))
          Text(policy.eventSource.title)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }

        Spacer(minLength: 0)

        Text("Priority \(policy.priority)")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      }

      policyRow(
        label: "Content",
        value: policy.match.contentKinds.map(\.title).sorted().joined(separator: ", "))
      policyRow(label: "Actions", value: policy.actions.map(\.title).joined(separator: ", "))
      policyRow(label: "Safety", value: commaList(policy.preprocessors.map(\.title)))
      policyRow(label: "After", value: commaList(policy.postprocessors.map(\.title)))

      if let sourceApps = sourceAppSummary(policy.match.sourceAppFilter) {
        policyRow(label: "Apps", value: sourceApps)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      PolicyCanvasVisualStyle.surface,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
    }
  }

  private func policyRow(label: String, value: String) -> some View {
    LabeledContent(label) {
      Text(value)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .multilineTextAlignment(.trailing)
    }
  }

  private var runtimeSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text("Runtime")
        .scaledFont(.headline.weight(.semibold))

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        Toggle(
          "Enable automation enforcement",
          isOn: Binding(
            get: { policyCenter.isAutomationEnabled },
            set: { policyCenter.setAutomationEnabled($0) }
          )
        )

        Text(
          """
          Keep this as the global on/off switch. Use the canvas and inspector to change the \
          rules themselves.
          """
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

        if let summary = policyCenter.lastClipboardEventSummary {
          LabeledContent("Last clipboard event") {
            VStack(alignment: .trailing, spacing: 2) {
              Text(summary)
                .scaledFont(.caption)
                .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                .multilineTextAlignment(.trailing)
              if let date = policyCenter.lastClipboardEventAt {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                  .scaledFont(.caption2)
                  .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
              }
            }
          }
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        PolicyCanvasVisualStyle.surface,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
      }
    }
  }

  @ViewBuilder private var recentActivitySection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text("Recent activity")
        .scaledFont(.headline.weight(.semibold))

      if policyCenter.recentAutomationEvents.isEmpty {
        Text("No policy activity yet")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
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
            if event.id != policyCenter.recentAutomationEvents.prefix(6).last?.id {
              Divider()
            }
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          PolicyCanvasVisualStyle.surface,
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(PolicyCanvasVisualStyle.subtleBorder, lineWidth: 1)
        }
      }
    }
  }

  private func commaList(_ values: [String]) -> String {
    values.isEmpty ? "None" : values.joined(separator: ", ")
  }

  private func sourceAppSummary(_ filter: AutomationSourceAppFilter) -> String? {
    switch filter.mode {
    case .allExceptDenied:
      guard !filter.deniedBundleIdentifiers.isEmpty else {
        return nil
      }
      return "Except \(filter.deniedBundleIdentifiers.joined(separator: ", "))"
    case .allowedOnly:
      let allowed = filter.allowedBundleIdentifiers.joined(separator: ", ")
      return allowed.isEmpty ? "Only selected apps" : "Only \(allowed)"
    }
  }
}
