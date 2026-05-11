import HarnessMonitorKit
import SwiftUI

struct AgentDetailHeaderFactStrip: View {
  let facts: [AgentDetailFact]

  private var visibleFacts: [AgentDetailFact] {
    facts.filter { !$0.isHiddenZero }
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
      ForEach(Array(visibleFacts.enumerated()), id: \.element.id) { index, fact in
        if index > 0 {
          Text("·")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk.opacity(0.6))
            .accessibilityHidden(true)
        }
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Text(fact.title)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.caption.bold())
            .foregroundStyle(fact.tint ?? HarnessMonitorTheme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fact.title)
        .accessibilityValue(fact.value)
      }
      Spacer(minLength: 0)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct AgentDetailRestingRuntimeLine: View {
  let lastActivity: String

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      Text("Stdout signals only — last seen \(lastActivity)")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Runtime")
    .accessibilityValue("Stdout signals only, last seen \(lastActivity)")
  }
}

struct AgentDetailReferenceDisclosure: View {
  let agentID: String
  let capabilityValues: [String]
  let hookPoints: [HookIntegrationDescriptor]

  @State private var isExpanded: Bool = true

  private var disclosureLabel: String {
    let capabilityCount = capabilityValues.count
    let hookCount = hookPoints.count
    let capabilityWord = capabilityCount == 1 ? "capability" : "capabilities"
    if hookCount > 0 {
      let hookWord = hookCount == 1 ? "hook point" : "hook points"
      return "Capabilities and hooks "
        + "(\(capabilityCount) \(capabilityWord), \(hookCount) \(hookWord))"
    }
    return "Capabilities and hooks (\(capabilityCount) \(capabilityWord))"
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        AgentDetailFactInlineRow(
          title: "Declared",
          inlineDescription: capabilityValues.joined(separator: " · ")
        )
        if !hookPoints.isEmpty {
          AgentDetailHookPointsInlineOrGrid(hookPoints: hookPoints)
        }
      }
      .padding(.top, HarnessMonitorTheme.spacingXS)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "info.circle")
          .scaledFont(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityHidden(true)
        Text(disclosureLabel)
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.agentDetailReferenceDisclosure(agentID)
    )
  }
}

struct AgentDetailFactInlineRow: View {
  let title: String
  let facts: [AgentDetailFact]
  let trailingDescription: String?
  let inlineDescription: String?

  init(
    title: String,
    facts: [AgentDetailFact] = [],
    trailingDescription: String? = nil,
    inlineDescription: String? = nil
  ) {
    self.title = title
    self.facts = facts
    self.trailingDescription = trailingDescription
    self.inlineDescription = inlineDescription
  }

  private var visibleFacts: [AgentDetailFact] {
    facts.filter { !$0.isHiddenZero }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityAddTraits(.isHeader)
      if !visibleFacts.isEmpty {
        factLine
      }
      if let inlineDescription, !inlineDescription.isEmpty {
        Text(inlineDescription)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let trailingDescription, !trailingDescription.isEmpty {
        Text(trailingDescription)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var factLine: some View {
    HarnessMonitorWrapLayout(
      spacing: HarnessMonitorTheme.spacingMD,
      lineSpacing: HarnessMonitorTheme.spacingXS
    ) {
      ForEach(visibleFacts) { fact in
        factItem(fact)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func factItem(_ fact: AgentDetailFact) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(fact.title)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
      Text(fact.value)
        .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
        .foregroundStyle(fact.tint ?? HarnessMonitorTheme.ink)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(fact.title)
    .accessibilityValue(fact.value)
  }
}

struct AgentDetailHookPointsInlineOrGrid: View {
  let hookPoints: [HookIntegrationDescriptor]

  var body: some View {
    if hookPoints.count == 1, let hook = hookPoints.first {
      hookInlineLine(hook)
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Hook points")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityAddTraits(.isHeader)
        AgentDetailHookPointsGrid(hookPoints: hookPoints)
      }
    }
  }

  private func hookInlineLine(_ hook: HookIntegrationDescriptor) -> some View {
    let trigger = AgentDetailHookPointsGrid.humanizedTrigger(for: hook)
    let context = hook.supportsContextInjection ? "context on" : "context off"
    let summary = "\(trigger) · \(hook.typicalLatencySeconds)s · \(context)"
    return HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Hook")
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(summary)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Hook")
    .accessibilityValue(summary)
  }
}
