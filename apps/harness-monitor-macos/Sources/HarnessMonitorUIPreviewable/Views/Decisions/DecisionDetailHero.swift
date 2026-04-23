import HarnessMonitorKit
import SwiftUI

/// Hero panel shown at the top of the Decisions detail column. Glass-backed so it reads as a
/// single canonical header: severity role badge, summary title, rule id, timestamps, and the
/// session / agent / task deeplink chips.
struct DecisionDetailHero: View {
  let viewModel: DecisionDetailViewModel
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        severityBadge
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          Text(viewModel.decision.summary)
            .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.leading)
          Text(viewModel.decision.ruleID)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        timestampBlock
      }
      if !viewModel.deeplinks.isEmpty {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(viewModel.deeplinks, id: \.stableKey) { deeplink in
            deeplinkBadge(deeplink)
          }
        }
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessPanelGlass()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDetailHero)
  }

  private var severityBadge: some View {
    Text(severityTitle(for: viewModel.severity))
      .scaledFont(.caption.bold())
      .foregroundStyle(severityTint(for: viewModel.severity))
      .harnessPillPadding()
      .harnessControlPill(tint: severityTint(for: viewModel.severity))
  }

  private var timestampBlock: some View {
    VStack(alignment: .trailing, spacing: HarnessMonitorTheme.spacingXS) {
      Text(viewModel.formattedAge(reference: .now))
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(formatTimestamp(viewModel.decision.createdAt, configuration: dateTimeConfiguration))
        .scaledFont(.caption.monospacedDigit())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private func deeplinkBadge(_ deeplink: DecisionDetailViewModel.Deeplink) -> some View {
    Label {
      Text(deeplink.id)
        .scaledFont(.caption.monospaced())
    } icon: {
      Image(systemName: deeplinkSymbol(deeplink.kind))
        .scaledFont(.caption.bold())
    }
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .harnessPillPadding()
    .harnessControlPill(tint: HarnessMonitorTheme.ink.opacity(0.6))
  }

  private var accessibilityLabel: String {
    let severity = severityTitle(for: viewModel.severity)
    let age = viewModel.formattedAge(reference: .now)
    let ruleID = viewModel.decision.ruleID
    let summary = viewModel.decision.summary
    return "\(severity) decision. \(summary). Rule \(ruleID). \(age)."
  }

  private func severityTitle(for severity: DecisionSeverity) -> String {
    switch severity {
    case .info: "Info"
    case .warn: "Warning"
    case .needsUser: "Needs User"
    case .critical: "Critical"
    }
  }

  private func severityTint(for severity: DecisionSeverity) -> Color {
    switch severity {
    case .info: HarnessMonitorTheme.accent
    case .warn: HarnessMonitorTheme.caution
    case .needsUser: HarnessMonitorTheme.warmAccent
    case .critical: HarnessMonitorTheme.danger
    }
  }

  private func deeplinkSymbol(_ kind: DecisionDetailViewModel.Deeplink.Kind) -> String {
    switch kind {
    case .session: "square.stack.3d.up"
    case .agent: "person.crop.circle"
    case .task: "checklist"
    }
  }
}

extension HarnessMonitorAccessibility {
  public static let decisionDetailHero = "harness.decisions.detail.hero"
}
