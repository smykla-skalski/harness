import HarnessMonitorKit
import SwiftUI

enum SettingsRepositoriesCatalogLoader {
  static func load(
    client: any HarnessMonitorClientProtocol,
    organization: String
  ) async throws -> ReviewsRepositoryCatalogResponse {
    let task = Task.detached(priority: .userInitiated) {
      let response = try await client.catalogReviewRepositories(
        request: ReviewsRepositoryCatalogRequest(organization: organization)
      )
      let repositories = response.repositories.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      return ReviewsRepositoryCatalogResponse(
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

extension SettingsRepositoriesSection {
  var organizationImportSection: some View {
    let visibleCatalogRepositories = filteredCatalogRepositories
    return Section {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        TextField("GitHub Organization", text: catalogOrganizationBinding)
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
        TextField("Search repositories", text: catalogSearchTextBinding)
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
        Reviews and Task Board toggles in the shared table above.
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
        let firstRepository = repositories.first
        ForEach(repositories, id: \.self) { repository in
          catalogRepositoryListRow(repository, isFirst: repository == firstRepository)
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

  private func catalogRepositoryListRow(_ repository: String, isFirst: Bool) -> some View {
    catalogRepositoryRow(repository)
      .overlay(alignment: .top) {
        Divider()
          .opacity(isFirst ? 0 : 1)
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
}
