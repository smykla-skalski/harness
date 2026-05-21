import HarnessMonitorKit
import SwiftUI

struct SettingsRepositoriesSection: View {
  let store: HarnessMonitorStore
  @Binding var taskBoardFormState: TaskBoardSettingsFormState
  @AppStorage(DashboardDependenciesPreferences.storageKey)
  var storedDependenciesPreferences = ""
  @State var draft = SettingsSharedRepositoriesDraft()
  @State var isLoading = false
  @State var isSaving = false
  @State var loadError: String?
  @State var saveWarning: String?
  @State var hasLoadedDraft = false
  @State var catalogOrganization = ""
  @State var loadedCatalogOrganization = ""
  @State var catalogRepositories: [String] = []
  @State var catalogSelection: Set<String> = []
  @State var catalogSearchText = ""
  @State var isCatalogLoading = false
  @State var catalogError: SettingsRepositoriesCatalogErrorPresentation?
  @State var isFullyExpanded = false

  @Environment(\.fontScale)
  var fontScale
  @Environment(\.openSettingsSection)
  var openSettingsSection
  @Environment(\.openURL)
  var openURL

  init(
    store: HarnessMonitorStore,
    formState: Binding<TaskBoardSettingsFormState>
  ) {
    self.store = store
    _taskBoardFormState = formState
  }

  var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  var filteredCatalogRepositories: [String] {
    let needle = catalogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !needle.isEmpty else {
      return catalogRepositories
    }
    return catalogRepositories.filter { $0.localizedCaseInsensitiveContains(needle) }
  }

  func catalogListHeight(visibleCount: Int) -> CGFloat {
    let visibleRows = min(max(visibleCount, 4), 8)
    return CGFloat(visibleRows) * 36
  }

  var body: some View {
    Form {
      if let loadError {
        statusSection(message: loadError)
      } else if isLoading {
        loadingSection
      } else {
        if let saveWarning {
          statusSection(message: saveWarning, color: .orange)
        }
        RepositoriesMonitoredSection(draft: $draft)
        if isFullyExpanded {
          organizationImportSection
          if !draft.legacyOrganizations.isEmpty {
            legacyOrganizationsSection
          }
        }
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRoot)
    .task { await loadDraftIfNeeded() }
    .task { await expandAfterFirstFrame() }
    .onChange(of: catalogError) { _, newValue in
      guard let newValue else { return }
      AccessibilityNotification.Announcement("\(newValue.title). \(newValue.message)").post()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionsBar
    }
  }

  func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
  }

  func statusSection(message: String, color: Color = .red) -> some View {
    Section {
      Text(message)
        .foregroundStyle(color)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  var loadingSection: some View {
    Section {
      ProgressView("Loading monitored repositories...")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  var actionsBar: some View {
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
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesReloadButton,
              action: { await reloadDraft(forceTaskBoardReload: true) }
            )
            HarnessMonitorAsyncActionButton(
              title: "Save",
              tint: nil,
              variant: .prominent,
              isLoading: isSaving,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesSaveButton,
              action: { await saveDraft() }
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

  var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  var normalizedCatalogOrganization: String? {
    SettingsGitHubRepositoryNormalization.normalized(catalogOrganization)?.lowercased()
  }
}
