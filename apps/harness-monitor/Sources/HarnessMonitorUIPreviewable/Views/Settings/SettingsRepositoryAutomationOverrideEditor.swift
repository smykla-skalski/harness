import HarnessMonitorKit
import SwiftUI

/// Edits one overridden group for one repository. Mounted only while the group
/// is overridden, so its seeded text state matches the stored value exactly once
/// and never has to be reconciled with an inherited one.
struct SettingsRepositoryAutomationOverrideEditor: View {
  let kind: SettingsRepositoryAutomationOverrideKind
  let repository: String
  let index: Int
  @Binding var draft: TaskBoardGitSettingsDraft

  @State private var reviewersText: String
  @State private var teamReviewersText: String
  @State private var protectedPathsText: String

  init(
    kind: SettingsRepositoryAutomationOverrideKind,
    repository: String,
    index: Int,
    draft: Binding<TaskBoardGitSettingsDraft>
  ) {
    self.kind = kind
    self.repository = repository
    self.index = index
    _draft = draft
    let reviewers = draft.wrappedValue.requestedReviewers(for: repository)
    _reviewersText = State(initialValue: reviewers.reviewers.joined(separator: "\n"))
    _teamReviewersText = State(initialValue: reviewers.teamReviewers.joined(separator: "\n"))
    _protectedPathsText = State(
      initialValue: draft.wrappedValue.protectedPaths(for: repository)
        .map(\.pattern)
        .joined(separator: "\n")
    )
  }

  var body: some View {
    switch kind {
    case .requestedReviewers: reviewersEditor
    case .protectedPaths: protectedPathsEditor
    case .labels: labelsEditor
    case .automations: automationsEditor
    }
  }

  private var reviewersEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      multiline(
        placeholder: "usernames, one per line",
        text: $reviewersText,
        label: "Requested reviewers for \(repository)",
        field: "reviewers"
      )
      multiline(
        placeholder: "team slugs, one per line",
        text: $teamReviewersText,
        label: "Requested team reviewers for \(repository)",
        field: "team-reviewers"
      )
    }
    .onChange(of: reviewersText) { commitReviewers() }
    .onChange(of: teamReviewersText) { commitReviewers() }
  }

  private var protectedPathsEditor: some View {
    multiline(
      placeholder: "protected paths, one per line",
      text: $protectedPathsText,
      label: "Protected paths for \(repository)",
      field: "protected-paths"
    )
    .onChange(of: protectedPathsText) {
      draft.setProtectedPaths(
        Self.entries(from: protectedPathsText).map(ProtectedPathRuleWire.init(pattern:)),
        for: repository
      )
    }
  }

  private var labelsEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      TextField("Managed Label", text: labelBinding(\.managed))
      TextField("Auto Merge Label", text: labelBinding(\.autoMerge))
      TextField("Needs Human Label", text: labelBinding(\.needsHuman))
      TextField("Protected Path Label", text: labelBinding(\.protectedPath))
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesOverrideField(index, "labels")
    )
  }

  private var automationsEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(TaskBoardGitHubAutomation.allCases, id: \.self) { automation in
        Toggle(automation.title, isOn: automationBinding(automation))
          .toggleStyle(.checkbox)
      }
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesOverrideField(index, "automations")
    )
  }

  private func multiline(
    placeholder: String,
    text: Binding<String>,
    label: String,
    field: String
  ) -> some View {
    HarnessMonitorMultilineTextField<Never>(
      placeholder: placeholder,
      text: text,
      minHeight: 64,
      accessibilityLabel: label
    )
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesOverrideField(index, field)
    )
  }

  private func commitReviewers() {
    draft.setRequestedReviewers(
      GitHubRequestedReviewersWire(
        reviewers: Self.entries(from: reviewersText),
        teamReviewers: Self.entries(from: teamReviewersText)
      ),
      for: repository
    )
  }

  private func labelBinding(
    _ keyPath: WritableKeyPath<GitHubAutomationLabelsWire, String>
  ) -> Binding<String> {
    Binding(
      get: { draft.labels(for: repository)[keyPath: keyPath] },
      set: { newValue in
        var labels = draft.labels(for: repository)
        labels[keyPath: keyPath] = newValue
        draft.setLabels(labels, for: repository)
      }
    )
  }

  private func automationBinding(_ automation: TaskBoardGitHubAutomation) -> Binding<Bool> {
    Binding(
      get: { draft.automations(for: repository).enabled.contains(automation) },
      set: { isEnabled in
        var enabled = Set(draft.automations(for: repository).enabled)
        if isEnabled {
          enabled.insert(automation)
        } else {
          enabled.remove(automation)
        }
        draft.setAutomations(
          GitHubAutomationTogglesWire(enabled: enabled.sorted { $0.rawValue < $1.rawValue }),
          for: repository
        )
      }
    )
  }

  private static func entries(from value: String) -> [String] {
    var entries: [String] = []
    var seen: Set<String> = []
    for line in value.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      entries.append(trimmed)
    }
    return entries
  }
}
