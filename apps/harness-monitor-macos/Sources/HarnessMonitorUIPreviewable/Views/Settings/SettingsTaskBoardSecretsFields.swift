import HarnessMonitorKit
import SwiftUI

extension SettingsTaskBoardEditingSurface {
  var credentialsSection: some View {
    Section {
      SettingsSecretField(
        title: "GitHub Token",
        placeholder: "Personal access token",
        field: draftBinding.globalToken,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField
      )
      SettingsSecretField(
        title: "Todoist Token",
        placeholder: "Optional Todoist API token",
        field: draftBinding.todoistToken,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField
          + ".todoist"
      )
      SettingsSecretField(
        title: "OpenRouter API Key",
        placeholder: "sk-or-...",
        field: draftBinding.openRouterToken,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardGlobalTokenField
          + ".openrouter"
      )
    } header: {
      Text("Credentials")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        "Tokens are stored in your macOS Keychain. "
          + "Click the trash icon to clear a stored value."
      )
    }
  }

  var repositoryOverridesHeader: some View {
    Section {
      Button {
        var updatedDraft = draft
        updatedDraft.repositoryOverrides.append(TaskBoardRepositoryOverrideDraft())
        draftBinding.wrappedValue = updatedDraft
      } label: {
        Label("Add Repository Override", systemImage: "plus")
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardAddOverrideButton)
    } header: {
      Text("Repository Overrides")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text("Use overrides for repo-specific identity, keys, or GitHub token values.")
    }
  }

  @ViewBuilder var repositoryOverrideSections: some View {
    ForEach(Array(draft.repositoryOverrides.enumerated()), id: \.element.id) { index, _ in
      Section {
        DisclosureGroup(repositoryOverrideTitle(index: index)) {
          TextField("owner/repo", text: draftBinding.repositoryOverrides[index].repository)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideField(index)
            )
          repositoryIdentityFields(index: index, override: draftBinding.repositoryOverrides[index])
          repositorySigningFields(index: index, override: draftBinding.repositoryOverrides[index])
          SettingsSecretField(
            title: "GitHub Token",
            placeholder: "Repository-specific token",
            field: draftBinding.repositoryOverrides[index].token,
            accessibilityIdentifier:
              HarnessMonitorAccessibility.settingsTaskBoardRepositoryOverrideTokenField(index)
          )
          Button(role: .destructive) {
            var updatedDraft = draft
            updatedDraft.repositoryOverrides.remove(at: index)
            draftBinding.wrappedValue = updatedDraft
          } label: {
            Label("Remove Override", systemImage: "trash")
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }

  func repositoryOverrideTitle(index: Int) -> String {
    let slug = draft.repositoryOverrides[index].repository
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if slug.isEmpty {
      return "Repository Override \(index + 1)"
    }
    return slug
  }
}
