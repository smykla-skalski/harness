import HarnessMonitorKit
import SwiftUI

struct TaskBoardSettingsFormState {
  var draft = TaskBoardGitSettingsDraft()
  var isLoading = false
  var isSaving = false
  var loadError: String?
  var hasLoadedSettings = false
}

protocol SettingsTaskBoardEditingSurface: View {
  var store: HarnessMonitorStore { get }
  var formState: Binding<TaskBoardSettingsFormState> { get }
}

extension SettingsTaskBoardEditingSurface {
  var draft: TaskBoardGitSettingsDraft {
    formState.wrappedValue.draft
  }

  var draftBinding: Binding<TaskBoardGitSettingsDraft> {
    Binding(
      get: { formState.wrappedValue.draft },
      set: { formState.wrappedValue.draft = $0 }
    )
  }

  var isLoading: Bool {
    formState.wrappedValue.isLoading
  }

  var isSaving: Bool {
    formState.wrappedValue.isSaving
  }

  var loadError: String? {
    formState.wrappedValue.loadError
  }

  var hasLoadedSettings: Bool {
    formState.wrappedValue.hasLoadedSettings
  }

  var isLoadingBinding: Binding<Bool> {
    Binding(
      get: { formState.wrappedValue.isLoading },
      set: { formState.wrappedValue.isLoading = $0 }
    )
  }

  var isSavingBinding: Binding<Bool> {
    Binding(
      get: { formState.wrappedValue.isSaving },
      set: { formState.wrappedValue.isSaving = $0 }
    )
  }

  var loadErrorBinding: Binding<String?> {
    Binding(
      get: { formState.wrappedValue.loadError },
      set: { formState.wrappedValue.loadError = $0 }
    )
  }

  var hasLoadedSettingsBinding: Binding<Bool> {
    Binding(
      get: { formState.wrappedValue.hasLoadedSettings },
      set: { formState.wrappedValue.hasLoadedSettings = $0 }
    )
  }

  @MainActor
  func loadSettingsIfNeeded() async {
    guard !isLoading, !hasLoadedSettings else { return }
    await loadSettings()
  }

  @MainActor
  func loadSettings() async {
    isLoadingBinding.wrappedValue = true
    hasLoadedSettingsBinding.wrappedValue = false
    defer { isLoadingBinding.wrappedValue = false }

    do {
      let snapshot = try await store.taskBoardGitSettingsSnapshot()
      draftBinding.wrappedValue = TaskBoardGitSettingsDraft(snapshot: snapshot)
      loadErrorBinding.wrappedValue = nil
      hasLoadedSettingsBinding.wrappedValue = true
    } catch {
      loadErrorBinding.wrappedValue = error.localizedDescription
      hasLoadedSettingsBinding.wrappedValue = false
    }
  }

  @MainActor
  func saveSettings() async {
    isSavingBinding.wrappedValue = true
    defer { isSavingBinding.wrappedValue = false }

    let succeeded = await store.updateTaskBoardGitSettings(
      snapshot: draftBinding.wrappedValue.snapshot
    )
    if succeeded {
      loadErrorBinding.wrappedValue = nil
      await loadSettings()
    }
  }

  func settingsPersistenceActionBar(
    reloadAccessibilityIdentifier: String,
    saveAccessibilityIdentifier: String
  ) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Spacer(minLength: 0)
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HarnessMonitorWrapLayout(
            spacing: HarnessMonitorTheme.itemSpacing,
            lineSpacing: HarnessMonitorTheme.itemSpacing,
            rowAlignment: .trailing
          ) {
            HarnessMonitorAsyncActionButton(
              title: "Reload",
              tint: .secondary,
              variant: .bordered,
              isLoading: isLoading,
              accessibilityIdentifier: reloadAccessibilityIdentifier,
              action: { await loadSettings() }
            )
            HarnessMonitorAsyncActionButton(
              title: "Save",
              tint: nil,
              variant: .prominent,
              isLoading: isSaving,
              accessibilityIdentifier: saveAccessibilityIdentifier,
              action: { await saveSettings() }
            )
            .disabled(isLoading || loadError != nil)
          }
        }
      }
      .padding(.horizontal, HarnessMonitorTheme.spacingXL)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .background(.background)
  }
}
