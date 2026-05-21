// swiftlint:disable file_length
import HarnessMonitorKit
import SwiftUI

private enum SettingsRepositoriesCatalogLoader {
  static func load(
    client: any HarnessMonitorClientProtocol,
    organization: String
  ) async throws -> DependencyUpdatesRepositoryCatalogResponse {
    let task = Task.detached(priority: .userInitiated) {
      let response = try await client.catalogDependencyUpdateRepositories(
        request: DependencyUpdatesRepositoryCatalogRequest(organization: organization)
      )
      let repositories = response.repositories.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      return DependencyUpdatesRepositoryCatalogResponse(
        organization: response.organization,
        repositories: repositories
      )
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

// swiftlint:disable:next type_body_length
struct SettingsRepositoriesSection: View {
  let store: HarnessMonitorStore
  @Binding private var taskBoardFormState: TaskBoardSettingsFormState
  @AppStorage(DashboardDependenciesPreferences.storageKey)
  private var storedDependenciesPreferences = ""
  @State private var draft = SettingsSharedRepositoriesDraft()
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var loadError: String?
  @State private var saveWarning: String?
  @State private var hasLoadedDraft = false
  @State private var catalogOrganization = ""
  @State private var loadedCatalogOrganization = ""
  @State private var catalogRepositories: [String] = []
  @State private var catalogSelection: Set<String> = []
  @State private var catalogSearchText = ""
  @State private var isCatalogLoading = false
  @State private var catalogError: SettingsRepositoriesCatalogErrorPresentation?

  @Environment(\.fontScale)
  private var fontScale
  @Environment(\.openSettingsSection)
  private var openSettingsSection
  @Environment(\.openURL)
  private var openURL

  init(
    store: HarnessMonitorStore,
    formState: Binding<TaskBoardSettingsFormState>
  ) {
    self.store = store
    _taskBoardFormState = formState
  }

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var filteredCatalogRepositories: [String] {
    let needle = catalogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !needle.isEmpty else {
      return catalogRepositories
    }
    return catalogRepositories.filter { $0.localizedCaseInsensitiveContains(needle) }
  }

  private var repositoriesTableRowsHeight: CGFloat {
    let visibleRows = min(draft.rows.count, 12)
    return CGFloat(visibleRows) * 44
  }

  private func catalogListHeight(visibleCount: Int) -> CGFloat {
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
        monitoredRepositoriesSection
        organizationImportSection
        if !draft.legacyOrganizations.isEmpty {
          legacyOrganizationsSection
        }
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRoot)
    .task { await loadDraftIfNeeded() }
    .onChange(of: catalogError) { _, newValue in
      guard let newValue else { return }
      AccessibilityNotification.Announcement("\(newValue.title). \(newValue.message)").post()
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionsBar
    }
  }

  private func statusSection(message: String, color: Color = .red) -> some View {
    Section {
      Text(message)
        .foregroundStyle(color)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var loadingSection: some View {
    Section {
      ProgressView("Loading monitored repositories...")
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesStatus)
    } header: {
      Text("Status")
        .harnessNativeFormSectionHeader()
    }
  }

  private var monitoredRepositoriesSection: some View {
    Section {
      repositoriesTable
      manualAddRow
    } header: {
      Text("Monitored Repositories")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Manage the shared repository scope for Dependencies and Task Board here. Turning both \
        feature toggles off removes the row.
        """
      )
    }
  }

  private var repositoriesTable: some View {
    VStack(spacing: 0) {
      repositoriesTableHeader
      Divider()

      if draft.rows.isEmpty {
        repositoriesEmptyRow
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(draft.rows.enumerated()), id: \.element.id) { index, row in
              repositoryTableRow(row, index: index)
            }
          }
        }
        .frame(height: repositoriesTableRowsHeight)
      }
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
  }

  private func repositoryTableRow(_ row: SettingsSharedRepositoryRow, index: Int) -> some View {
    repositoryRow(row, index: index)
      .overlay(alignment: .top) {
        Divider()
          .opacity(index == 0 ? 0 : 1)
      }
  }

  private var repositoriesTableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text("Owner")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Repository")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Dependencies")
        .frame(width: 116, alignment: .center)
      Text("Task Board")
        .frame(width: 110, alignment: .center)
      Text("Action")
        .frame(width: 72, alignment: .trailing)
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var repositoriesEmptyRow: some View {
    Label("No monitored repositories configured", systemImage: "shippingbox")
      .font(bodyFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRow(0))
  }

  private func repositoryRow(_ row: SettingsSharedRepositoryRow, index: Int) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(row.owner)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.repository)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(
        "Dependencies",
        isOn: Binding(
          get: { row.dependenciesEnabled },
          set: { draft.setDependenciesEnabled($0, for: row.id) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .frame(width: 116, alignment: .center)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesDependenciesToggle(index)
      )
      Toggle(
        "Task Board",
        isOn: Binding(
          get: { row.taskBoardEnabled },
          set: { draft.setTaskBoardEnabled($0, for: row.id) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .frame(width: 110, alignment: .center)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesTaskBoardToggle(index)
      )
      Button(role: .destructive) {
        draft.remove(rowID: row.id)
      } label: {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(row.repositoryPath)")
      .accessibilityLabel("Remove \(row.repositoryPath)")
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRemoveButton(index))
      .frame(width: 72, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRow(index))
  }

  private var manualAddRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      SettingsTaskBoardInboxTextField(
        placeholder: "owner",
        text: $draft.ownerInput,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesOwnerField,
        onSubmit: addManualRepository
      )

      SettingsTaskBoardInboxTextField(
        placeholder: "repository",
        text: $draft.repositoryInput,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesNameField,
        onSubmit: addManualRepository
      )

      Button(action: addManualRepository) {
        Label("Add Repository", systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .lineLimit(1)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(!draft.canAddManualRepository)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesAddButton)
    }
  }

  private var organizationImportSection: some View {
    let visibleCatalogRepositories = filteredCatalogRepositories
    return Section {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        TextField("GitHub Organization", text: $catalogOrganization)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsRepositoriesOrganizationField
          )
          .onSubmit {
            Task { await loadCatalogForCurrentOrganization() }
          }

        HarnessMonitorAsyncActionButton(
          title: "Load Repositories",
          tint: .secondary,
          variant: .bordered,
          isLoading: isCatalogLoading,
          accessibilityIdentifier: HarnessMonitorAccessibility
            .settingsRepositoriesOrgLoadButton,
          action: { await loadCatalogForCurrentOrganization() }
        )
        .disabled(normalizedCatalogOrganization == nil)
      }

      if let catalogError {
        catalogErrorView(catalogError)
      }

      if !loadedCatalogOrganization.isEmpty {
        catalogSummary(visibleCount: visibleCatalogRepositories.count)
        TextField("Search repositories", text: $catalogSearchText)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.settingsRepositoriesCatalogSearchField)

        if catalogRepositories.isEmpty {
          Label("No repositories available for import", systemImage: "shippingbox")
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesCatalogList)
        } else if visibleCatalogRepositories.isEmpty {
          Label("No repositories match the current search", systemImage: "magnifyingglass")
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesCatalogList)
        } else {
          catalogRepositoryList(visibleCatalogRepositories)

          HStack(spacing: HarnessMonitorTheme.spacingSM) {
            Button("Select Visible") {
              catalogSelection = Set(visibleCatalogRepositories)
            }
            .buttonStyle(.borderless)

            Button("Clear Selection") {
              catalogSelection = []
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Add Selected") {
              addCatalogRepositories(Array(catalogSelection))
            }
            .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
            .disabled(catalogSelection.isEmpty)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.settingsRepositoriesCatalogAddButton
            )

            Button("Add All") {
              addCatalogRepositories(catalogRepositories)
            }
            .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
            .disabled(catalogRepositories.isEmpty)
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.settingsRepositoriesCatalogAddAllButton
            )
          }
        }
      }
    } header: {
      Text("Organization Import")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Search and import repositories from a GitHub organization, then tune each row's \
        Dependencies and Task Board toggles in the shared table above.
        """
      )
    }
  }

  private func catalogErrorView(_ error: SettingsRepositoriesCatalogErrorPresentation) -> some View
  {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(error.title, systemImage: "exclamationmark.triangle.fill")
        .font(captionSemibold)
        .foregroundStyle(.orange)
        .accessibilityAddTraits(.isHeader)

      Text(error.message)
        .font(bodyFont)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)

      if let action = error.action {
        Button(action.title) {
          performCatalogErrorAction(action)
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityHint(error.actionHint)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.spacingMD)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.orange.opacity(0.45), lineWidth: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesCatalogStatus)
  }

  private func catalogRepositoryList(_ repositories: [String]) -> some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(repositories.enumerated()), id: \.element) { row in
          let index = row.offset
          let repository = row.element
          catalogRepositoryListRow(repository, index: index)
        }
      }
    }
    .frame(height: catalogListHeight(visibleCount: repositories.count))
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesCatalogList)
  }

  private func catalogRepositoryListRow(_ repository: String, index: Int) -> some View {
    catalogRepositoryRow(repository)
      .overlay(alignment: .top) {
        Divider()
          .opacity(index == 0 ? 0 : 1)
      }
  }

  private func catalogRepositoryRow(_ repository: String) -> some View {
    Toggle(
      isOn: Binding(
        get: { catalogSelection.contains(repository) },
        set: { isSelected in
          if isSelected {
            catalogSelection.insert(repository)
          } else {
            catalogSelection.remove(repository)
          }
        }
      )
    ) {
      Text(repository)
        .font(bodyFont)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .toggleStyle(.checkbox)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func catalogSummary(visibleCount: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(loadedCatalogOrganization)
          .font(captionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text(
          "\(catalogRepositories.count) repositories loaded · "
            + "\(visibleCount) visible"
        )
        .font(bodyFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      if !catalogSelection.isEmpty {
        Text("\(catalogSelection.count) selected")
          .font(bodyFont)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
  }

  private var legacyOrganizationsSection: some View {
    Section {
      ForEach(Array(draft.legacyOrganizations.enumerated()), id: \.element) { index, organization in
        legacyOrganizationRow(organization, index: index)
      }
    } header: {
      Text("Legacy Organization Sources")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Older Dependencies settings may still monitor whole organizations. Import them into \
        concrete repository rows when you're ready, or remove them to stop querying that \
        organization.
        """
      )
    }
  }

  private func legacyOrganizationRow(_ organization: String, index: Int) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: 4) {
        Text(organization)
          .font(bodyFont.weight(.semibold))
        Text("Dependencies still queries this legacy organization until you import or remove it.")
          .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      Spacer()
      Button("Review Repositories") {
        Task { await loadCatalog(for: organization, preselectVisible: true) }
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .fixedSize(horizontal: true, vertical: true)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesLegacyImportButton(index)
      )
      Button("Remove") {
        draft.removeLegacyOrganization(organization)
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .red)
      .fixedSize(horizontal: true, vertical: true)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesLegacyRemoveButton(index)
      )
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .overlay(alignment: .top) {
      Divider()
        .opacity(index == 0 ? 0 : 1)
    }
  }

  private var actionsBar: some View {
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

  private var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  private var normalizedCatalogOrganization: String? {
    SettingsGitHubRepositoryNormalization.normalized(catalogOrganization)?.lowercased()
  }

  @MainActor
  private func loadDraftIfNeeded() async {
    guard !isLoading, !hasLoadedDraft else { return }
    await reloadDraft(forceTaskBoardReload: false)
  }

  @MainActor
  private func reloadDraft(forceTaskBoardReload: Bool) async {
    isLoading = true
    loadError = nil
    saveWarning = nil
    defer { isLoading = false }

    do {
      try await ensureTaskBoardSettingsLoaded(forceReload: forceTaskBoardReload)
      let dependenciesPreferences = DashboardDependenciesPreferences.decode(
        from: storedDependenciesPreferences
      ).normalized()
      draft = SettingsSharedRepositoriesDraft(
        dependenciesPreferences: dependenciesPreferences,
        taskBoardDraft: taskBoardFormState.draft
      )
      hasLoadedDraft = true
      resetCatalogState()
    } catch {
      loadError = error.localizedDescription
      hasLoadedDraft = false
    }
  }

  @MainActor
  private func ensureTaskBoardSettingsLoaded(forceReload: Bool) async throws {
    guard forceReload || !taskBoardFormState.hasLoadedSettings else { return }
    taskBoardFormState.isLoading = true
    defer { taskBoardFormState.isLoading = false }
    let snapshot = try await store.taskBoardGitSettingsSnapshot()
    taskBoardFormState.draft = TaskBoardGitSettingsDraft(snapshot: snapshot)
    taskBoardFormState.loadError = nil
    taskBoardFormState.hasLoadedSettings = true
  }

  @MainActor
  private func loadCatalogForCurrentOrganization() async {
    guard let organization = normalizedCatalogOrganization else { return }
    await loadCatalog(for: organization, preselectVisible: false)
  }

  @MainActor
  private func loadCatalog(for organization: String, preselectVisible: Bool) async {
    isCatalogLoading = true
    catalogError = nil
    defer { isCatalogLoading = false }

    do {
      guard let client = store.apiClient else {
        throw HarnessMonitorAPIError.server(code: 501, message: "Repositories unavailable")
      }
      let response = try await SettingsRepositoriesCatalogLoader.load(
        client: client,
        organization: organization
      )
      loadedCatalogOrganization = response.organization
      catalogOrganization = response.organization
      catalogRepositories = response.repositories
      catalogSearchText = ""
      catalogSelection = preselectVisible ? Set(response.repositories) : []
    } catch {
      catalogError = SettingsRepositoriesCatalogErrorPresentation(
        error: error,
        organization: organization
      )
      loadedCatalogOrganization = ""
      catalogRepositories = []
      catalogSelection = []
      catalogSearchText = ""
    }
  }

  @MainActor
  private func saveDraft() async {
    guard loadError == nil else { return }
    isSaving = true
    saveWarning = nil
    defer { isSaving = false }

    var taskBoardDraft = taskBoardFormState.draft
    taskBoardDraft.githubInboxRepositoriesText = draft.taskBoardRepositories.joined(separator: "\n")

    let dependenciesRepositories = draft.dependenciesRepositories
    let legacyOrganizations = draft.legacyOrganizations

    let succeeded = await store.updateTaskBoardGitSettings(
      snapshot: taskBoardDraft.snapshot,
      origin: .settingsRepositoriesSaveButton
    )
    guard succeeded else { return }

    var dependenciesPreferences = DashboardDependenciesPreferences.decode(
      from: storedDependenciesPreferences
    ).normalized()
    dependenciesPreferences.repositoriesText = dependenciesRepositories.joined(separator: ", ")
    dependenciesPreferences.organizationsText = legacyOrganizations.joined(separator: ", ")
    let normalizedPreferences = dependenciesPreferences.normalized()
    storedDependenciesPreferences = normalizedPreferences.encodedString

    do {
      let snapshot = try await store.taskBoardGitSettingsSnapshot()
      taskBoardFormState.draft = TaskBoardGitSettingsDraft(snapshot: snapshot)
      taskBoardFormState.loadError = nil
      taskBoardFormState.hasLoadedSettings = true
      draft = SettingsSharedRepositoriesDraft(
        dependenciesPreferences: normalizedPreferences,
        taskBoardDraft: taskBoardFormState.draft
      )
      hasLoadedDraft = true
      loadError = nil
    } catch {
      taskBoardFormState.draft = taskBoardDraft
      taskBoardFormState.loadError = nil
      taskBoardFormState.hasLoadedSettings = true
      draft = SettingsSharedRepositoriesDraft(
        dependenciesPreferences: normalizedPreferences,
        taskBoardDraft: taskBoardDraft
      )
      hasLoadedDraft = true
      loadError = nil
      saveWarning =
        "Saved changes, but reloading the latest settings failed: \(error.localizedDescription)"
    }
  }

  private func addManualRepository() {
    draft.addManualRepository()
  }

  private func addCatalogRepositories(_ repositories: [String]) {
    draft.addImportedRepositories(repositories)
    catalogSelection.subtract(repositories)
  }

  private func resetCatalogState() {
    catalogOrganization = ""
    loadedCatalogOrganization = ""
    catalogRepositories = []
    catalogSelection = []
    catalogSearchText = ""
    catalogError = nil
    isCatalogLoading = false
  }

  private func performCatalogErrorAction(
    _ action: SettingsRepositoriesCatalogErrorPresentation.RecoveryAction
  ) {
    switch action {
    case .openSecrets:
      openSettingsSection(.secrets)
    case .openURL(let url):
      openURL(url)
    }
  }
}

struct SettingsRepositoriesCatalogErrorPresentation: Equatable {
  enum RecoveryAction: Equatable {
    case openSecrets
    case openURL(URL)

    var title: String {
      switch self {
      case .openSecrets:
        "Open Secrets"
      case .openURL:
        "Open Token Settings"
      }
    }
  }

  let title: String
  let message: String
  let action: RecoveryAction?

  init(title: String, message: String, action: RecoveryAction?) {
    self.title = title
    self.message = message
    self.action = action
  }

  init(error: any Error, organization: String) {
    self = Self.presentation(for: error, organization: organization)
  }

  var actionHint: String {
    switch action {
    case .openSecrets:
      "Open the Secrets settings section."
    case .openURL:
      "Open GitHub token settings in your browser."
    case nil:
      ""
    }
  }

  private static func presentation(
    for error: any Error,
    organization: String
  ) -> Self {
    let rawMessage = sourceMessage(from: error)
    let normalized = rawMessage.lowercased()
    let organizationReference = organization.isEmpty ? "this organization" : organization

    if normalized.contains("requires a github token") {
      return Self(
        title: "GitHub token required",
        message: "Add a GitHub token in Settings > Secrets, then load repositories again.",
        action: .openSecrets
      )
    }

    if normalized.contains("forbids access via a fine-grained personal access") {
      let action = tokenSettingsAction(in: rawMessage)
      if normalized.contains("token's lifetime is greater than 366 days") {
        return Self(
          title: "GitHub token needs attention",
          message:
            "GitHub blocked access to \(organizationReference) because the current "
            + "fine-grained token exceeds the organization's lifetime policy. "
            + "Update the token, then load repositories again.",
          action: action
        )
      }

      return Self(
        title: "GitHub access is blocked",
        message:
          "GitHub blocked access to \(organizationReference) for the current fine-grained "
          + "token. Update the token's organization access, then load repositories again.",
        action: action
      )
    }

    if normalized.contains("was not found or is not accessible")
      || normalized.contains("could not resolve to an organization")
    {
      return Self(
        title: "Organization unavailable",
        message:
          "GitHub couldn't load repositories for \(organizationReference). Check the "
          + "organization name and confirm the current token can access it, then try again.",
        action: nil
      )
    }

    if normalized.contains("rate limit") {
      return Self(
        title: "GitHub is rate limiting requests",
        message: "Wait a moment, then load repositories again.",
        action: nil
      )
    }

    if normalized.contains("bad credentials") || normalized.contains("unauthorized") {
      return Self(
        title: "GitHub token was rejected",
        message: "Update the GitHub token in Settings > Secrets, then load repositories again.",
        action: .openSecrets
      )
    }

    return Self(
      title: "Couldn't load repositories",
      message:
        "GitHub couldn't load repositories for \(organizationReference). Check the "
        + "organization name and your GitHub access, then try again.",
      action: nil
    )
  }

  private static func sourceMessage(from error: any Error) -> String {
    if let apiError = error as? HarnessMonitorAPIError {
      return apiError.serverMessage ?? apiError.errorDescription ?? error.localizedDescription
    }
    return error.localizedDescription
  }

  private static func tokenSettingsAction(in message: String) -> RecoveryAction? {
    guard
      let range = message.range(
        of: #"https://github\.com/settings/personal-access-tokens/[^\s)]+"#,
        options: .regularExpression
      )
    else {
      return nil
    }
    let urlString = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
    guard let url = URL(string: urlString) else {
      return nil
    }
    return .openURL(url)
  }
}

private struct SettingsSharedRepositoryRow: Identifiable, Equatable {
  let owner: String
  let repository: String
  var dependenciesEnabled: Bool
  var taskBoardEnabled: Bool

  var repositoryPath: String { "\(owner)/\(repository)" }
  var id: String { repositoryPath.lowercased() }
}

private struct SettingsSharedRepositoriesDraft: Equatable {
  var rows: [SettingsSharedRepositoryRow] = []
  var legacyOrganizations: [String] = []
  var ownerInput = ""
  var repositoryInput = ""

  init() {}

  init(
    dependenciesPreferences: DashboardDependenciesPreferences,
    taskBoardDraft: TaskBoardGitSettingsDraft
  ) {
    var rowIndexes = [String: Int]()
    insert(
      repositories: dependenciesPreferences.normalizedRepositories,
      dependenciesEnabled: true,
      taskBoardEnabled: false,
      rowIndexes: &rowIndexes
    )
    insert(
      repositories: taskBoardDraft.githubInboxRepositoryEntries,
      dependenciesEnabled: false,
      taskBoardEnabled: true,
      rowIndexes: &rowIndexes
    )
    legacyOrganizations = Self.normalizedOrganizations(
      dependenciesPreferences.normalizedOrganizations)
  }

  var canAddManualRepository: Bool {
    SettingsGitHubRepositoryNormalization.repository(
      owner: ownerInput,
      repo: repositoryInput
    ) != nil
  }

  var dependenciesRepositories: [String] {
    rows.filter(\.dependenciesEnabled).map(\.repositoryPath)
  }

  var taskBoardRepositories: [String] {
    rows.filter(\.taskBoardEnabled).map(\.repositoryPath)
  }

  mutating func addManualRepository() {
    guard
      let repository = SettingsGitHubRepositoryNormalization.repository(
        owner: ownerInput,
        repo: repositoryInput
      )
    else {
      return
    }
    var rowIndexes = rowIndexesByID()
    insert(
      repository: repository,
      dependenciesEnabled: true,
      taskBoardEnabled: true,
      rowIndexes: &rowIndexes
    )
    ownerInput = ""
    repositoryInput = ""
  }

  mutating func addImportedRepositories(_ repositories: [String]) {
    var rowIndexes = rowIndexesByID()
    insert(
      repositories: repositories,
      dependenciesEnabled: true,
      taskBoardEnabled: true,
      rowIndexes: &rowIndexes
    )
  }

  mutating func setDependenciesEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    rows[index].dependenciesEnabled = isEnabled
    removeIfDisabled(index: index)
  }

  mutating func setTaskBoardEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
    rows[index].taskBoardEnabled = isEnabled
    removeIfDisabled(index: index)
  }

  mutating func remove(rowID: String) {
    rows.removeAll { $0.id == rowID }
  }

  mutating func removeLegacyOrganization(_ organization: String) {
    let normalized = organization.lowercased()
    legacyOrganizations.removeAll { $0.lowercased() == normalized }
  }

  private mutating func insert(
    repositories: [String],
    dependenciesEnabled: Bool,
    taskBoardEnabled: Bool,
    rowIndexes: inout [String: Int]
  ) {
    for repository in repositories {
      insert(
        repository: repository,
        dependenciesEnabled: dependenciesEnabled,
        taskBoardEnabled: taskBoardEnabled,
        rowIndexes: &rowIndexes
      )
    }
  }

  private mutating func insert(
    repository: String,
    dependenciesEnabled: Bool,
    taskBoardEnabled: Bool,
    rowIndexes: inout [String: Int]
  ) {
    guard let normalized = SettingsGitHubRepositoryNormalization.repositoryEntry(repository) else {
      return
    }
    let parts = normalized.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return }
    let candidate = SettingsSharedRepositoryRow(
      owner: parts[0],
      repository: parts[1],
      dependenciesEnabled: dependenciesEnabled,
      taskBoardEnabled: taskBoardEnabled
    )
    if let index = rowIndexes[candidate.id] {
      rows[index].dependenciesEnabled = rows[index].dependenciesEnabled || dependenciesEnabled
      rows[index].taskBoardEnabled = rows[index].taskBoardEnabled || taskBoardEnabled
      return
    }
    rowIndexes[candidate.id] = rows.count
    rows.append(candidate)
  }

  private func rowIndexesByID() -> [String: Int] {
    Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
  }

  private mutating func removeIfDisabled(index: Int) {
    guard rows.indices.contains(index) else { return }
    guard !rows[index].dependenciesEnabled, !rows[index].taskBoardEnabled else { return }
    rows.remove(at: index)
  }

  private static func normalizedOrganizations(_ organizations: [String]) -> [String] {
    var normalized: [String] = []
    var seen: Set<String> = []
    for organization in organizations {
      guard let value = SettingsGitHubRepositoryNormalization.normalized(organization)?.lowercased()
      else {
        continue
      }
      if seen.insert(value).inserted {
        normalized.append(value)
      }
    }
    return normalized
  }
}
