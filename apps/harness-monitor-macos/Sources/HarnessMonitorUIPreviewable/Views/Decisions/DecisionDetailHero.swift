import HarnessMonitorKit
import SwiftUI

/// Hero panel shown at the top of the Decisions detail column. Glass-backed so it reads as a
/// single canonical header: severity role, summary title, rule id, timestamps, and lightweight
/// scope context. Keep this calm so the decision reads like a document header instead of a card.
struct DecisionDetailHero: View {
  let viewModel: DecisionDetailViewModel
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
          severityLabel
          Text(viewModel.decision.summary)
            .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
          Text("Source · \(humanizedWorkspaceLabel(viewModel.decision.ruleID))")
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        }
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        timestampBlock
      }
      if !viewModel.deeplinks.isEmpty {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          ForEach(viewModel.deeplinks, id: \.stableKey) { deeplink in
            scopeItem(deeplink)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionDetailHero)
  }

  private var severityLabel: some View {
    Label(
      severityTitle(for: viewModel.severity),
      systemImage: severitySymbol(for: viewModel.severity)
    )
    .scaledFont(.subheadline.weight(.semibold))
    .foregroundStyle(severityTint(for: viewModel.severity))
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

  private func scopeItem(_ deeplink: DecisionDetailViewModel.Deeplink) -> some View {
    Label {
      Text(scopeItemTitle(deeplink))
        .lineLimit(1)
        .truncationMode(.middle)
    } icon: {
      Image(systemName: deeplinkSymbol(deeplink.kind))
        .accessibilityHidden(true)
    }
    .scaledFont(.caption)
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }

  private var accessibilityLabel: String {
    let severity = severityTitle(for: viewModel.severity)
    let age = viewModel.formattedAge(reference: .now)
    let source = humanizedWorkspaceLabel(viewModel.decision.ruleID)
    let summary = viewModel.decision.summary
    return "\(severity) decision. \(summary). Source \(source). \(age)."
  }

  private func scopeItemTitle(_ deeplink: DecisionDetailViewModel.Deeplink) -> String {
    humanizedWorkspaceLabel(deeplink.id)
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

  private func severitySymbol(for severity: DecisionSeverity) -> String {
    switch severity {
    case .info:
      "info.circle.fill"
    case .warn:
      "exclamationmark.triangle.fill"
    case .needsUser:
      "person.fill.questionmark"
    case .critical:
      "exclamationmark.octagon.fill"
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
