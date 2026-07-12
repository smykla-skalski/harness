import HarnessMonitorKit
import SwiftUI

struct SettingsRepositoriesSection: View {
  let store: HarnessMonitorStore
  @Binding var taskBoardFormState: TaskBoardSettingsFormState
  let isActive: Bool
  @AppStorage(DashboardReviewsPreferences.storageKey)
  var storedReviewsPreferences = ""
  @AppStorage(SettingsRepositoriesCatalog.storageKey)
  var storedRepositoryCatalog = ""
  @State private var draftStorage = SettingsSharedRepositoriesDraft()
  @State private var isLoadingStorage = false
  @State private var isSavingStorage = false
  @State private var loadErrorStorage: String?
  @State private var saveWarningStorage: String?
  @State private var hasLoadedDraftStorage = false
  @State private var catalogOrganizationStorage = ""
  @State private var loadedCatalogOrganizationStorage = ""
  @State private var catalogRepositoriesStorage: [String] = []
  @State private var catalogSelectionStorage: Set<String> = []
  @State private var catalogSearchTextStorage = ""
  @State private var isCatalogLoadingStorage = false
  @State private var catalogErrorStorage: SettingsRepositoriesCatalogErrorPresentation?
  @State private var isFullyExpandedStorage = false

  @Environment(\.fontScale)
  var fontScale
  @Environment(\.openSettingsSection)
  var openSettingsSection
  @Environment(\.openURL)
  var openURL

  init(
    store: HarnessMonitorStore,
    formState: Binding<TaskBoardSettingsFormState>,
    isActive: Bool = true
  ) {
    self.store = store
    self.isActive = isActive
    _taskBoardFormState = formState
  }

  var draft: SettingsSharedRepositoriesDraft {
    get { draftStorage }
    nonmutating set { draftStorage = newValue }
  }

  var draftBinding: Binding<SettingsSharedRepositoriesDraft> {
    $draftStorage
  }

  var isLoading: Bool {
    get { isLoadingStorage }
    nonmutating set { isLoadingStorage = newValue }
  }

  var isSaving: Bool {
    get { isSavingStorage }
    nonmutating set { isSavingStorage = newValue }
  }

  var loadError: String? {
    get { loadErrorStorage }
    nonmutating set { loadErrorStorage = newValue }
  }

  var saveWarning: String? {
    get { saveWarningStorage }
    nonmutating set { saveWarningStorage = newValue }
  }

  var hasLoadedDraft: Bool {
    get { hasLoadedDraftStorage }
    nonmutating set { hasLoadedDraftStorage = newValue }
  }

  var catalogOrganization: String {
    get { catalogOrganizationStorage }
    nonmutating set { catalogOrganizationStorage = newValue }
  }

  var catalogOrganizationBinding: Binding<String> {
    $catalogOrganizationStorage
  }

  var loadedCatalogOrganization: String {
    get { loadedCatalogOrganizationStorage }
    nonmutating set { loadedCatalogOrganizationStorage = newValue }
  }

  var catalogRepositories: [String] {
    get { catalogRepositoriesStorage }
    nonmutating set { catalogRepositoriesStorage = newValue }
  }

  var catalogSelection: Set<String> {
    get { catalogSelectionStorage }
    nonmutating set { catalogSelectionStorage = newValue }
  }

  var catalogSearchText: String {
    get { catalogSearchTextStorage }
    nonmutating set { catalogSearchTextStorage = newValue }
  }

  var catalogSearchTextBinding: Binding<String> {
    $catalogSearchTextStorage
  }

  var isCatalogLoading: Bool {
    get { isCatalogLoadingStorage }
    nonmutating set { isCatalogLoadingStorage = newValue }
  }

  var catalogError: SettingsRepositoriesCatalogErrorPresentation? {
    get { catalogErrorStorage }
    nonmutating set { catalogErrorStorage = newValue }
  }

  var isFullyExpanded: Bool {
    get { isFullyExpandedStorage }
    nonmutating set { isFullyExpandedStorage = newValue }
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
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      if let loadError {
        statusSection(message: loadError)
      } else if isLoading {
        loadingSection
      } else {
        if let saveWarning {
          statusSection(message: saveWarning, color: .orange)
        }
        RepositoriesMonitoredSection(draft: draftBinding)
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
    .task(id: isActive) {
      guard isActive else { return }
      await loadDraftIfNeeded()
    }
    .task(id: isActive) {
      guard isActive else { return }
      await expandAfterFirstFrame()
    }
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
