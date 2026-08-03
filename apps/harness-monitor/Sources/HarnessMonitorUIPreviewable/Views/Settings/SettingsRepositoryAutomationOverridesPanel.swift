import HarnessMonitorKit
import SwiftUI

/// The publication conventions one repository uses, shown under its row in the
/// monitored-repositories table. Every group renders the value the repository
/// resolves to; an inherited group renders it greyed and read-only, so "same as
/// global" stays distinguishable from "pinned here".
struct SettingsRepositoryAutomationOverridesPanel: View {
  let repository: String
  let index: Int
  @Binding var draft: TaskBoardGitSettingsDraft

  @Environment(\.fontScale)
  private var fontScale

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      ForEach(SettingsRepositoryAutomationOverrideKind.allCases) { kind in
        group(kind)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  @ViewBuilder
  private func group(_ kind: SettingsRepositoryAutomationOverrideKind) -> some View {
    let isOverridden = draft.overrides(kind, for: repository)
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      header(kind, isOverridden: isOverridden)
      if isOverridden {
        SettingsRepositoryAutomationOverrideEditor(
          kind: kind,
          repository: repository,
          index: index,
          draft: $draft
        )
      } else {
        inheritedValue(kind)
      }
    }
  }

  private func header(
    _ kind: SettingsRepositoryAutomationOverrideKind,
    isOverridden: Bool
  ) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(kind.title)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: 0)
      if isOverridden {
        Button("Revert to global") {
          draft.stopOverriding(kind, for: repository)
        }
        .buttonStyle(.borderless)
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.accent)
      }
      Toggle(
        "Override \(kind.title)",
        isOn: Binding(
          get: { isOverridden },
          set: { shouldOverride in
            if shouldOverride {
              draft.beginOverriding(kind, for: repository)
            } else {
              draft.stopOverriding(kind, for: repository)
            }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
      .harnessNativeFormControl()
      .frame(minHeight: 24)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesOverrideToggle(index, kind.rawValue)
      )
    }
  }

  private func inheritedValue(_ kind: SettingsRepositoryAutomationOverrideKind) -> some View {
    Text(inheritedSummary(kind))
      .font(captionFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func inheritedSummary(_ kind: SettingsRepositoryAutomationOverrideKind) -> String {
    switch kind {
    case .requestedReviewers:
      let reviewers = draft.globalRequestedReviewers
      let entries = reviewers.reviewers + reviewers.teamReviewers.map { "@\($0)" }
      return entries.isEmpty ? "No reviewers requested" : entries.joined(separator: ", ")
    case .protectedPaths:
      let patterns = draft.globalProtectedPaths.map(\.pattern)
      return patterns.isEmpty ? "No protected paths" : patterns.joined(separator: ", ")
    case .labels:
      let labels = draft.globalLabels
      return [labels.managed, labels.autoMerge, labels.needsHuman, labels.protectedPath]
        .joined(separator: " · ")
    case .automations:
      let enabled = draft.globalAutomations.enabled
      return enabled.isEmpty
        ? "Every automation off" : enabled.map(\.title).joined(separator: ", ")
    }
  }
}
