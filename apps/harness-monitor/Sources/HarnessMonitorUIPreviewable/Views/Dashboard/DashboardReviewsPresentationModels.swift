import HarnessMonitorKit

struct DashboardReviewsItemGroup: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case pinned
    case repository(String)
    case status(String)
    case author(String)

    var title: String {
      switch self {
      case .pinned: "Pinned"
      case .repository(let value): value
      case .status(let value): value
      case .author(let value): value
      }
    }

    var rawValue: String {
      switch self {
      case .pinned: "pinned"
      case .repository(let value): "repository:\(value)"
      case .status(let value): "status:\(value)"
      case .author(let value): "author:\(value)"
      }
    }
  }

  let kind: Kind
  let items: [ReviewItem]

  var id: String { kind.rawValue }

  // Back-compat accessor for callers that only handle repository groups.
  var repository: String {
    if case .repository(let value) = kind { return value }
    return ""
  }
}

typealias DashboardReviewsRepositoryGroup = DashboardReviewsItemGroup

struct DashboardReviewsItemsVersion: Equatable, Sendable {
  private enum Storage: Equatable, Sendable {
    case revision(UInt64)
    case snapshot([ReviewItem])
  }

  private let storage: Storage

  init(revision: UInt64) {
    storage = .revision(revision)
  }

  init(snapshot items: [ReviewItem]) {
    storage = .snapshot(items)
  }
}

struct DashboardReviewsPresentationInput: Equatable, Sendable {
  let items: [ReviewItem]
  let itemsVersion: DashboardReviewsItemsVersion
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let configuredAuthors: [String]
  let selectedIDs: Set<String>
  let persistedPrimarySelectionID: String
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool

  init(
    items: [ReviewItem],
    itemsVersion: DashboardReviewsItemsVersion? = nil,
    filterModeRaw: String,
    sortModeRaw: String,
    groupModeRaw: String = DashboardReviewsGroupMode.repository.rawValue,
    categoryModeRaw: String,
    searchText: String,
    configuredRepositories: [String],
    configuredOrganizations: [String],
    configuredAuthors: [String] = [],
    selectedIDs: Set<String>,
    persistedPrimarySelectionID: String,
    pinnedPullRequestIDs: [String] = [],
    needsMeOn: Bool = false,
    dependenciesOnlyOn: Bool = false
  ) {
    self.items = items
    self.itemsVersion = itemsVersion ?? DashboardReviewsItemsVersion(snapshot: items)
    self.filterModeRaw = filterModeRaw
    self.sortModeRaw = sortModeRaw
    self.groupModeRaw = groupModeRaw
    self.categoryModeRaw = categoryModeRaw
    self.searchText = searchText
    self.configuredRepositories = configuredRepositories
    self.configuredOrganizations = configuredOrganizations
    self.configuredAuthors = configuredAuthors
    self.selectedIDs = selectedIDs
    self.persistedPrimarySelectionID = persistedPrimarySelectionID
    self.pinnedPullRequestIDs = pinnedPullRequestIDs
    self.needsMeOn = needsMeOn
    self.dependenciesOnlyOn = dependenciesOnlyOn
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selectedIDs == rhs.selectedIDs
      && lhs.persistedPrimarySelectionID == rhs.persistedPrimarySelectionID
      && lhs.filterModeRaw == rhs.filterModeRaw
      && lhs.sortModeRaw == rhs.sortModeRaw
      && lhs.groupModeRaw == rhs.groupModeRaw
      && lhs.categoryModeRaw == rhs.categoryModeRaw
      && lhs.searchText == rhs.searchText
      && lhs.configuredRepositories == rhs.configuredRepositories
      && lhs.configuredOrganizations == rhs.configuredOrganizations
      && lhs.configuredAuthors == rhs.configuredAuthors
      && lhs.pinnedPullRequestIDs == rhs.pinnedPullRequestIDs
      && lhs.needsMeOn == rhs.needsMeOn
      && lhs.dependenciesOnlyOn == rhs.dependenciesOnlyOn
      && lhs.itemsVersion == rhs.itemsVersion
  }
}

struct DashboardReviewsPresentationTaskID: Equatable, Sendable {
  let itemsVersion: DashboardReviewsItemsVersion
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let preferencesSignature: String
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool
}

struct DashboardReviewsPresentationSelectionID: Equatable, Sendable {
  let selectedIDs: Set<String>
  let persistedPrimarySelectionID: String
  let sortModeRaw: String
}

struct DashboardReviewsListPresentationInput: Equatable, Sendable {
  let items: [ReviewItem]
  let itemsVersion: DashboardReviewsItemsVersion
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let configuredAuthors: [String]
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool

  init(_ input: DashboardReviewsPresentationInput) {
    self.init(
      items: input.items,
      itemsVersion: input.itemsVersion,
      filterModeRaw: input.filterModeRaw,
      sortModeRaw: input.sortModeRaw,
      groupModeRaw: input.groupModeRaw,
      categoryModeRaw: input.categoryModeRaw,
      searchText: input.searchText,
      configuredRepositories: input.configuredRepositories,
      configuredOrganizations: input.configuredOrganizations,
      configuredAuthors: input.configuredAuthors,
      pinnedPullRequestIDs: input.pinnedPullRequestIDs,
      needsMeOn: input.needsMeOn,
      dependenciesOnlyOn: input.dependenciesOnlyOn
    )
  }

  init(
    items: [ReviewItem],
    itemsVersion: DashboardReviewsItemsVersion,
    filterModeRaw: String,
    sortModeRaw: String,
    groupModeRaw: String,
    categoryModeRaw: String,
    searchText: String,
    configuredRepositories: [String],
    configuredOrganizations: [String],
    configuredAuthors: [String],
    pinnedPullRequestIDs: [String],
    needsMeOn: Bool,
    dependenciesOnlyOn: Bool
  ) {
    self.items = items
    self.itemsVersion = itemsVersion
    self.filterModeRaw = filterModeRaw
    self.sortModeRaw = sortModeRaw
    self.groupModeRaw = groupModeRaw
    self.categoryModeRaw = categoryModeRaw
    self.searchText = searchText
    self.configuredRepositories = configuredRepositories
    self.configuredOrganizations = configuredOrganizations
    self.configuredAuthors = configuredAuthors
    self.pinnedPullRequestIDs = pinnedPullRequestIDs
    self.needsMeOn = needsMeOn
    self.dependenciesOnlyOn = dependenciesOnlyOn
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.filterModeRaw == rhs.filterModeRaw
      && lhs.sortModeRaw == rhs.sortModeRaw
      && lhs.groupModeRaw == rhs.groupModeRaw
      && lhs.categoryModeRaw == rhs.categoryModeRaw
      && lhs.searchText == rhs.searchText
      && lhs.configuredRepositories == rhs.configuredRepositories
      && lhs.configuredOrganizations == rhs.configuredOrganizations
      && lhs.configuredAuthors == rhs.configuredAuthors
      && lhs.pinnedPullRequestIDs == rhs.pinnedPullRequestIDs
      && lhs.needsMeOn == rhs.needsMeOn
      && lhs.dependenciesOnlyOn == rhs.dependenciesOnlyOn
      && lhs.itemsVersion == rhs.itemsVersion
  }
}

struct DashboardReviewsListPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    itemsByID: [:],
    relativeUpdatedLabels: [:],
    version: .empty
  )

  let filteredItems: [ReviewItem]
  let groupedItems: [DashboardReviewsRepositoryGroup]
  let itemsByID: [String: ReviewItem]
  let relativeUpdatedLabels: [String: String]
  let version: DashboardReviewsListPresentationVersion
}

struct DashboardReviewsListPresentationVersion: Equatable, Sendable {
  static let empty = Self(
    itemsVersion: DashboardReviewsItemsVersion(revision: 0),
    filterModeRaw: "",
    sortModeRaw: "",
    groupModeRaw: "",
    categoryModeRaw: "",
    searchText: "",
    configuredRepositories: [],
    configuredOrganizations: [],
    configuredAuthors: [],
    pinnedPullRequestIDs: [],
    needsMeOn: false,
    dependenciesOnlyOn: false
  )

  let itemsVersion: DashboardReviewsItemsVersion
  let filterModeRaw: String
  let sortModeRaw: String
  let groupModeRaw: String
  let categoryModeRaw: String
  let searchText: String
  let configuredRepositories: [String]
  let configuredOrganizations: [String]
  let configuredAuthors: [String]
  let pinnedPullRequestIDs: [String]
  let needsMeOn: Bool
  let dependenciesOnlyOn: Bool

  init(input: DashboardReviewsListPresentationInput) {
    self.init(
      itemsVersion: input.itemsVersion,
      filterModeRaw: input.filterModeRaw,
      sortModeRaw: input.sortModeRaw,
      groupModeRaw: input.groupModeRaw,
      categoryModeRaw: input.categoryModeRaw,
      searchText: input.searchText,
      configuredRepositories: input.configuredRepositories,
      configuredOrganizations: input.configuredOrganizations,
      configuredAuthors: input.configuredAuthors,
      pinnedPullRequestIDs: input.pinnedPullRequestIDs,
      needsMeOn: input.needsMeOn,
      dependenciesOnlyOn: input.dependenciesOnlyOn
    )
  }

  init(
    itemsVersion: DashboardReviewsItemsVersion,
    filterModeRaw: String,
    sortModeRaw: String,
    groupModeRaw: String,
    categoryModeRaw: String,
    searchText: String,
    configuredRepositories: [String],
    configuredOrganizations: [String],
    configuredAuthors: [String],
    pinnedPullRequestIDs: [String],
    needsMeOn: Bool,
    dependenciesOnlyOn: Bool
  ) {
    self.itemsVersion = itemsVersion
    self.filterModeRaw = filterModeRaw
    self.sortModeRaw = sortModeRaw
    self.groupModeRaw = groupModeRaw
    self.categoryModeRaw = categoryModeRaw
    self.searchText = searchText
    self.configuredRepositories = configuredRepositories
    self.configuredOrganizations = configuredOrganizations
    self.configuredAuthors = configuredAuthors
    self.pinnedPullRequestIDs = pinnedPullRequestIDs
    self.needsMeOn = needsMeOn
    self.dependenciesOnlyOn = dependenciesOnlyOn
  }
}

struct DashboardReviewsPresentation: Equatable, Sendable {
  static let empty = Self(
    filteredItems: [],
    groupedItems: [],
    itemsByID: [:],
    selectedItems: [],
    primaryDetailItem: nil,
    relativeUpdatedLabels: [:],
    version: .empty
  )

  let filteredItems: [ReviewItem]
  let groupedItems: [DashboardReviewsRepositoryGroup]
  let itemsByID: [String: ReviewItem]
  let selectedItems: [ReviewItem]
  let primaryDetailItem: ReviewItem?
  let relativeUpdatedLabels: [String: String]
  let version: DashboardReviewsPresentationVersion

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.version == rhs.version
  }
}

struct DashboardReviewsPresentationVersion: Equatable, Sendable {
  static let empty = Self(
    listVersion: .empty,
    selectedPullRequestIDs: [],
    primaryDetailPullRequestID: nil
  )

  let listVersion: DashboardReviewsListPresentationVersion
  let selectedPullRequestIDs: [String]
  let primaryDetailPullRequestID: String?
}
