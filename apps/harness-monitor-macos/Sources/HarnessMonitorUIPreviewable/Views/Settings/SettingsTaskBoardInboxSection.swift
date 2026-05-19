import SwiftUI

struct SettingsTaskBoardInboxSection: View {
  @Binding var draft: TaskBoardGitSettingsDraft

  var body: some View {
    Section {
      SettingsTaskBoardInboxRepositoryList(
        entries: draft.githubInboxRepositoryEntries,
        ownerInput: $draft.githubInboxRepositoryOwnerInput,
        repoInput: $draft.githubInboxRepositoryNameInput,
        canAdd: draft.canAddGitHubInboxRepository,
        add: { draft.addGitHubInboxRepositoryInput() },
        remove: { draft.removeGitHubInboxRepository($0) }
      )

      SettingsTaskBoardInboxEntryList(
        title: "Label Filter",
        valueTitle: "Label",
        entries: draft.githubInboxLabelEntries,
        emptyTitle: "All labels",
        emptySystemImage: "line.3.horizontal.decrease.circle",
        inputPlaceholder: "label",
        input: $draft.githubInboxLabelInput,
        addTitle: "Add Label",
        addAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTBInboxLabelAddButton,
        inputAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTaskBoardInboxLabelFilterField,
        rowAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTBInboxLabelRow,
        removeAccessibilityIdentifier:
          HarnessMonitorAccessibility.settingsTBInboxLabelRemoveButton,
        canAdd: draft.canAddGitHubInboxLabel,
        add: { draft.addGitHubInboxLabelInput() },
        remove: { draft.removeGitHubInboxLabel($0) }
      )
    } header: {
      Text("GitHub Inbox")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Import assigned issues and requested reviews into Needs You. Empty label filters mean all \
        labels are included.
        """
      )
    }
  }
}

private struct SettingsTaskBoardInboxEntryList: View {
  let title: String
  let valueTitle: String
  let entries: [String]
  let emptyTitle: String
  let emptySystemImage: String
  let inputPlaceholder: String
  @Binding var input: String
  let addTitle: String
  let addAccessibilityIdentifier: String
  let inputAccessibilityIdentifier: String
  let rowAccessibilityIdentifier: (Int) -> String
  let removeAccessibilityIdentifier: (Int) -> String
  let canAdd: Bool
  let add: () -> Void
  let remove: (String) -> Void

  @Environment(\.fontScale)
  private var fontScale

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      table
    }
  }

  private var table: some View {
    VStack(spacing: 0) {
      tableHeader
      Divider()

      if entries.isEmpty {
        emptyRow
      } else {
        ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
          if index > 0 {
            Divider()
          }
          entryRow(entry, index: index)
        }
      }

      Divider()
      addRow
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
  }

  private var tableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(valueTitle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Action")
        .frame(width: 120, alignment: .trailing)
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var emptyRow: some View {
    Label(emptyTitle, systemImage: emptySystemImage)
      .font(bodyFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .accessibilityIdentifier(rowAccessibilityIdentifier(0))
  }

  private func entryRow(_ entry: String, index: Int) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(entry)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        remove(entry)
      } label: {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(entry)")
      .accessibilityLabel("Remove \(entry)")
      .accessibilityIdentifier(removeAccessibilityIdentifier(index))
      .frame(width: 120, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityIdentifier(rowAccessibilityIdentifier(index))
  }

  private var addRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      TextField(inputPlaceholder, text: $input)
        .font(bodyFont)
        .textFieldStyle(.roundedBorder)
        .harnessNativeFormControl()
        .onSubmit(addIfPossible)
        .accessibilityIdentifier(inputAccessibilityIdentifier)

      Button(action: addIfPossible) {
        Label(addTitle, systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(!canAdd)
      .accessibilityIdentifier(addAccessibilityIdentifier)
      .frame(width: 120, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  private func addIfPossible() {
    guard canAdd else {
      return
    }
    add()
  }
}

private struct SettingsTaskBoardInboxRepositoryList: View {
  let entries: [String]
  @Binding var ownerInput: String
  @Binding var repoInput: String
  let canAdd: Bool
  let add: () -> Void
  let remove: (String) -> Void

  @Environment(\.fontScale)
  private var fontScale

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Repositories")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      table
    }
  }

  private var table: some View {
    VStack(spacing: 0) {
      tableHeader
      Divider()

      if entries.isEmpty {
        emptyRow
      } else {
        ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
          if index > 0 {
            Divider()
          }
          entryRow(entry, index: index)
        }
      }

      Divider()
      addRow
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
  }

  private var tableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text("Owner")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Repository")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Action")
        .frame(width: 140, alignment: .trailing)
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var emptyRow: some View {
    Label("No repositories added", systemImage: "tray")
      .font(bodyFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoRow(0))
  }

  private func entryRow(_ entry: String, index: Int) -> some View {
    let repository = repositoryParts(entry)
    return HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(repository.owner)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(repository.repo)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        remove(entry)
      } label: {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(entry)")
      .accessibilityLabel("Remove \(entry)")
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoRemoveButton(index))
      .frame(width: 140, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoRow(index))
  }

  private var addRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      TextField("owner", text: $ownerInput)
        .font(bodyFont)
        .textFieldStyle(.roundedBorder)
        .harnessNativeFormControl()
        .onSubmit(addIfPossible)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoOwnerField)

      TextField("repository", text: $repoInput)
        .font(bodyFont)
        .textFieldStyle(.roundedBorder)
        .harnessNativeFormControl()
        .onSubmit(addIfPossible)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoNameField)

      Button(action: addIfPossible) {
        Label("Add Repository", systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.accent)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(!canAdd)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTBInboxRepoAddButton)
      .frame(width: 140, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  private func addIfPossible() {
    guard canAdd else {
      return
    }
    add()
  }

  private func repositoryParts(_ entry: String) -> (owner: String, repo: String) {
    let parts = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return (entry, "")
    }
    return (String(parts[0]), String(parts[1]))
  }
}
