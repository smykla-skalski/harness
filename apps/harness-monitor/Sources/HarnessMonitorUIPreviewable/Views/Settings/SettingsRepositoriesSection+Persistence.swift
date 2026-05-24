import HarnessMonitorKit
import SwiftUI

extension SettingsRepositoriesSection {
  var legacyOrganizationsSection: some View {
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
        Older Reviews settings may still monitor whole organizations. Import them into \
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
        Text("Reviews still queries this legacy organization until you import or remove it.")
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

  @MainActor
  func loadDraftIfNeeded() async {
    guard !isLoading, !hasLoadedDraft else { return }
    await reloadDraft(forceTaskBoardReload: false)
  }

  @MainActor
  func reloadDraft(forceTaskBoardReload: Bool) async {
    isLoading = true
    loadError = nil
    saveWarning = nil
    defer { isLoading = false }

    do {
      try await ensureTaskBoardSettingsLoaded(forceReload: forceTaskBoardReload)
      let reviewsPreferences = DashboardReviewsPreferences.decode(
        from: storedReviewsPreferences
      ).normalized()
      draft = SettingsSharedRepositoriesDraft(
        reviewsPreferences: reviewsPreferences,
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
  func loadCatalogForCurrentOrganization() async {
    guard let organization = normalizedCatalogOrganization else { return }
    await loadCatalog(for: organization, preselectVisible: false)
  }

  @MainActor
  func loadCatalog(for organization: String, preselectVisible: Bool) async {
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
  func saveDraft() async {
    guard loadError == nil else { return }
    isSaving = true
    saveWarning = nil
    defer { isSaving = false }

    var taskBoardDraft = taskBoardFormState.draft
    taskBoardDraft.githubInboxRepositoriesText = draft.taskBoardRepositories.joined(separator: "\n")

    let reviewsRepositories = draft.reviewsRepositories
    let legacyOrganizations = draft.legacyOrganizations

    let succeeded = await store.updateTaskBoardGitSettings(
      snapshot: taskBoardDraft.snapshot,
      origin: .settingsRepositoriesSaveButton
    )
    guard succeeded else { return }

    var reviewsPreferences = DashboardReviewsPreferences.decode(
      from: storedReviewsPreferences
    ).normalized()
    reviewsPreferences.repositoriesText = reviewsRepositories.joined(separator: ", ")
    reviewsPreferences.organizationsText = legacyOrganizations.joined(separator: ", ")
    let normalizedPreferences = reviewsPreferences.normalized()
    storedReviewsPreferences = normalizedPreferences.encodedString

    do {
      let snapshot = try await store.taskBoardGitSettingsSnapshot()
      taskBoardFormState.draft = TaskBoardGitSettingsDraft(snapshot: snapshot)
      taskBoardFormState.loadError = nil
      taskBoardFormState.hasLoadedSettings = true
      draft = SettingsSharedRepositoriesDraft(
        reviewsPreferences: normalizedPreferences,
        taskBoardDraft: taskBoardFormState.draft
      )
      hasLoadedDraft = true
      loadError = nil
    } catch {
      taskBoardFormState.draft = taskBoardDraft
      taskBoardFormState.loadError = nil
      taskBoardFormState.hasLoadedSettings = true
      draft = SettingsSharedRepositoriesDraft(
        reviewsPreferences: normalizedPreferences,
        taskBoardDraft: taskBoardDraft
      )
      hasLoadedDraft = true
      loadError = nil
      saveWarning =
        "Saved changes, but reloading the latest settings failed: \(error.localizedDescription)"
    }
  }

  func addManualRepository() {
    draft.addManualRepository()
  }

  func addCatalogRepositories(_ repositories: [String]) {
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

  func performCatalogErrorAction(
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
