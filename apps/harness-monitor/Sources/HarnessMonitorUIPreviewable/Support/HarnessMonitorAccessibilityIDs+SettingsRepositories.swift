extension HarnessMonitorAccessibility {
  public static let settingsRepositoriesRoot = "harness.settings.repositories"
  public static let settingsRepositoriesStatus = "harness.settings.repositories.status"
  public static let settingsRepositoriesReloadButton = "harness.settings.repositories.reload"
  public static let settingsRepositoriesSaveButton = "harness.settings.repositories.save"
  public static let settingsRepositoriesOwnerField = "harness.settings.repositories.owner"
  public static let settingsRepositoriesNameField = "harness.settings.repositories.name"
  public static let settingsRepositoriesAddButton = "harness.settings.repositories.add"
  public static let settingsRepoTaskBoardScopeSummary =
    "harness.settings.repositories.task-board.scope.summary"
  public static let settingsRepoTaskBoardEnableAllButton =
    "harness.settings.repositories.task-board.enable-all"
  public static let settingsRepoTaskBoardDisableAllButton =
    "harness.settings.repositories.task-board.disable-all"
  public static let settingsRepositoriesOrganizationField =
    "harness.settings.repositories.organization"
  public static let settingsRepositoriesOrgLoadButton =
    "harness.settings.repositories.organization.load"
  public static let settingsRepositoriesCatalogStatus =
    "harness.settings.repositories.catalog.status"
  public static let settingsRepositoriesCatalogSearchField =
    "harness.settings.repositories.catalog.search"
  public static let settingsRepositoriesCatalogList =
    "harness.settings.repositories.catalog.list"
  public static let settingsRepositoriesCatalogAddButton =
    "harness.settings.repositories.catalog.add-selected"
  public static let settingsRepositoriesCatalogAddAllButton =
    "harness.settings.repositories.catalog.add-all"

  public static func settingsRepositoriesRow(_ index: Int) -> String {
    "harness.settings.repositories.\(index).row"
  }

  public static func settingsRepositoriesReviewsToggle(_ index: Int) -> String {
    "harness.settings.repositories.\(index).reviews"
  }

  public static func settingsRepositoriesTaskBoardToggle(_ index: Int) -> String {
    "harness.settings.repositories.\(index).task-board"
  }

  public static func settingsRepositoriesTaskBoardOnlyButton(_ index: Int) -> String {
    "harness.settings.repositories.\(index).task-board.only"
  }

  public static func settingsRepositoriesRemoveButton(_ index: Int) -> String {
    "harness.settings.repositories.\(index).remove"
  }

  public static func settingsRepositoriesOverridesDisclosure(_ index: Int) -> String {
    "harness.settings.repositories.\(index).overrides"
  }

  public static func settingsRepositoriesOverrideToggle(_ index: Int, _ kind: String) -> String {
    "harness.settings.repositories.\(index).overrides.\(kind)"
  }

  public static func settingsRepositoriesOverrideField(_ index: Int, _ field: String) -> String {
    "harness.settings.repositories.\(index).overrides.field.\(field)"
  }
}
