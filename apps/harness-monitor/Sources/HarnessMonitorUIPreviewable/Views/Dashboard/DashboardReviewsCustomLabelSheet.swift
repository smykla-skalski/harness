import HarnessMonitorKit
import SwiftUI

@MainActor
struct DashboardReviewsCustomLabelSheet: View {
  let items: [ReviewItem]
  let suggestions: [ReviewRepositoryLabel]
  @Binding var draft: String
  let onApply: (String) -> Void
  let onCancel: () -> Void

  @FocusState private var fieldFocused: Bool

  private var trimmedDraft: String {
    draft.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canApply: Bool {
    !trimmedDraft.isEmpty
  }

  private var subtitle: String {
    let repos = Set(items.map { $0.repository }).count
    switch (items.count, repos) {
    case (1, _):
      return "Apply a label to 1 pull request"
    case (let prCount, 1):
      return "Apply a label to \(prCount) pull requests in 1 repository"
    case (let prCount, let repoCount):
      return "Apply a label to \(prCount) pull requests across \(repoCount) repositories"
    }
  }

  private var unusedSuggestions: [ReviewRepositoryLabel] {
    let trimmedLower = trimmedDraft.lowercased()
    guard !trimmedLower.isEmpty else { return Array(suggestions.prefix(6)) }
    return Array(
      suggestions
        .filter { $0.name.lowercased().contains(trimmedLower) }
        .prefix(6)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      header
      labelField
      if !unusedSuggestions.isEmpty {
        suggestionList
      }
      Spacer(minLength: 0)
      Divider()
      footer
    }
    .padding(HarnessMonitorTheme.spacingXL)
    .frame(width: 460)
    .frame(minHeight: 260)
    .background(.background)
    .onSubmit(applyIfPossible)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.dashboardReviewsCustomLabelSheet
    )
  }

  private var header: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingMD) {
      Image(systemName: "tag")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.accent)
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text("Add Custom Label")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Text(subtitle)
          .scaledFont(.callout)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  private var labelField: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Label name")
        .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      TextField("e.g. dependencies", text: $draft)
        .textFieldStyle(.roundedBorder)
        .controlSize(.regular)
        .focused($fieldFocused)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.dashboardReviewsCustomLabelField
        )
        .task { fieldFocused = true }
      Text("Created on GitHub if it doesn't exist yet.")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var suggestionList: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Existing labels")
        .scaledFont(.system(.subheadline, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.spacingSM,
        lineSpacing: HarnessMonitorTheme.spacingSM
      ) {
        ForEach(unusedSuggestions) { label in
          Button {
            draft = label.name
          } label: {
            suggestionChip(label)
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }

  private func suggestionChip(_ label: ReviewRepositoryLabel) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Circle()
        .fill(
          dashboardReviewsLabelSwatchColor(label.color)
            ?? HarnessMonitorTheme.secondaryInk.opacity(0.5)
        )
        .frame(width: 8, height: 8)
      Text(label.name)
        .scaledFont(.caption.weight(.medium))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(1)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, 4)
    .background(
      Capsule(style: .continuous)
        .fill(HarnessMonitorTheme.secondaryInk.opacity(0.12))
    )
    .overlay(
      Capsule(style: .continuous)
        .strokeBorder(HarnessMonitorTheme.secondaryInk.opacity(0.18), lineWidth: 1)
    )
    .contentShape(Capsule(style: .continuous))
  }

  private var footer: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Spacer(minLength: 0)
      HarnessMonitorActionButton(
        title: "Cancel",
        tint: .secondary,
        variant: .bordered,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.dashboardReviewsCustomLabelCancel
      ) {
        onCancel()
      }
      HarnessMonitorActionButton(
        title: "Apply",
        variant: .prominent,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.dashboardReviewsCustomLabelApply
      ) {
        applyIfPossible()
      }
      .disabled(!canApply)
    }
  }

  private func applyIfPossible() {
    guard canApply else { return }
    onApply(trimmedDraft)
  }
}
