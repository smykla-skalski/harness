import Foundation
import HarnessMonitorKit

struct DashboardDependenciesPreferences: Codable, Equatable {
  static let storageKey = "dashboard.dependencies.preferences"
  static let minimumPerRepositoryIntervalSeconds: UInt64 = 30
  static let maximumPerRepositoryIntervalSeconds: UInt64 = 3_600
  static let minimumConcurrentRepositoryFetches: Int = 1
  static let maximumConcurrentRepositoryFetches: Int = 8
  static let minimumFrequentLabelsCount: Int = 1
  static let maximumFrequentLabelsCount: Int = 10
  static let defaultFrequentLabelsCount: Int = 5

  static let minimumTimelinePageSize: Int = 10
  static let maximumTimelinePageSize: Int = 100
  static let defaultTimelinePageSize: Int = 50
  static let defaultTimelineHiddenKindsRaw: String = "mentioned,subscribed,unsubscribed"

  var authorsText = "renovate[bot]"
  var organizationsText = ""
  var repositoriesText = ""
  var excludeRepositoriesText = ""
  var mergeMethodRaw = TaskBoardGitHubMergeMethod.squash.rawValue
  var refreshIntervalSeconds: UInt64 = 300
  var cacheMaxAgeSeconds: UInt64 = 600
  var showLabelDescriptions = false
  var frequentLabelsCount: Int = defaultFrequentLabelsCount
  var perRepositoryIntervalSeconds: UInt64 = 300
  var maxConcurrentRepositoryFetches: Int = 2
  var expandOrganizations: Bool = true
  var filesEnabled: Bool = true
  var filesDefaultViewModeRaw: String = FilesViewMode.unified.rawValue
  var filesSplitMinColumnPoints: Int = 280
  var filesAutoPrefetchPatchCap: Int = 25
  var filesAutoCollapseHunkLineThreshold: Int = 500
  var filesHideGenerated: Bool = true
  var filesGeneratedPatterns: [String] = Self.defaultGeneratedPatterns
  var filesHideWhitespaceOnly: Bool = false
  var filesMarkViewedSyncWithGitHub: Bool = true
  var filesShowImagePreview: Bool = true
  var filesTreeDefaultExpandedDepth: Int = 2
  var filesImagePreviewMaxBytes: Int = 5 * 1024 * 1024
  var filesLargeDiffStrategyRaw: String = FilesLargeDiffStrategy.autoLocalClone.rawValue
  var filesLocalCloneThresholdLines: Int = 500
  var filesLocalCloneDiskBudgetMB: Int = 5_120
  var filesLocalCloneMaxAgeDays: Int = 30
  var filesAccessibilityPerLineMode: Bool = false
  var showActivityTimeline: Bool = true
  var timelineHiddenKindsRaw: String = defaultTimelineHiddenKindsRaw
  var timelineInitialPageSize: Int = defaultTimelinePageSize
  var timelineLoadOlderBatchSize: Int = defaultTimelinePageSize
  var timelineAutoCollapseHeavyReviewThreads: Bool = true

  enum CodingKeys: String, CodingKey {
    case authorsText
    case organizationsText
    case repositoriesText
    case excludeRepositoriesText
    case mergeMethodRaw
    case refreshIntervalSeconds
    case cacheMaxAgeSeconds
    case showLabelDescriptions
    case frequentLabelsCount
    case perRepositoryIntervalSeconds
    case maxConcurrentRepositoryFetches
    case expandOrganizations
    case filesEnabled
    case filesDefaultViewModeRaw
    case filesSplitMinColumnPoints
    case filesAutoPrefetchPatchCap
    case filesAutoCollapseHunkLineThreshold
    case filesHideGenerated
    case filesGeneratedPatterns
    case filesHideWhitespaceOnly
    case filesMarkViewedSyncWithGitHub
    case filesShowImagePreview
    case filesTreeDefaultExpandedDepth
    case filesImagePreviewMaxBytes
    case filesLargeDiffStrategyRaw
    case filesLocalCloneThresholdLines
    case filesLocalCloneDiskBudgetMB
    case filesLocalCloneMaxAgeDays
    case filesAccessibilityPerLineMode
    case showActivityTimeline
    case timelineHiddenKindsRaw
    case timelineInitialPageSize
    case timelineLoadOlderBatchSize
    case timelineAutoCollapseHeavyReviewThreads
  }

  static let defaultGeneratedPatterns: [String] = [
    "(^|/)package-lock\\.json$",
    "(^|/)yarn\\.lock$",
    "(^|/)pnpm-lock\\.yaml$",
    "(^|/)Cargo\\.lock$",
    "(^|/)Package\\.resolved$",
    "(^|/)Gemfile\\.lock$",
    "(^|/)poetry\\.lock$",
    "(^|/)go\\.sum$",
    "(^|/)vendor/",
    "(^|/)node_modules/",
    "(^|/)dist/",
    "\\.pb\\.go$",
    "\\.pb\\.cc$",
    "\\.generated\\.(swift|ts|js)$",
  ]

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    authorsText =
      try container.decodeIfPresent(String.self, forKey: .authorsText) ?? defaults.authorsText
    organizationsText =
      try container.decodeIfPresent(String.self, forKey: .organizationsText)
      ?? defaults.organizationsText
    repositoriesText =
      try container.decodeIfPresent(String.self, forKey: .repositoriesText)
      ?? defaults.repositoriesText
    excludeRepositoriesText =
      try container.decodeIfPresent(String.self, forKey: .excludeRepositoriesText)
      ?? defaults.excludeRepositoriesText
    mergeMethodRaw =
      try container.decodeIfPresent(String.self, forKey: .mergeMethodRaw)
      ?? defaults.mergeMethodRaw
    refreshIntervalSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .refreshIntervalSeconds)
      ?? defaults.refreshIntervalSeconds
    cacheMaxAgeSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .cacheMaxAgeSeconds)
      ?? defaults.cacheMaxAgeSeconds
    showLabelDescriptions =
      try container.decodeIfPresent(Bool.self, forKey: .showLabelDescriptions)
      ?? defaults.showLabelDescriptions
    frequentLabelsCount =
      try container.decodeIfPresent(Int.self, forKey: .frequentLabelsCount)
      ?? defaults.frequentLabelsCount
    perRepositoryIntervalSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .perRepositoryIntervalSeconds)
      ?? refreshIntervalSeconds
    maxConcurrentRepositoryFetches =
      try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRepositoryFetches)
      ?? defaults.maxConcurrentRepositoryFetches
    expandOrganizations =
      try container.decodeIfPresent(Bool.self, forKey: .expandOrganizations)
      ?? defaults.expandOrganizations
    filesEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .filesEnabled) ?? defaults.filesEnabled
    filesDefaultViewModeRaw =
      try container.decodeIfPresent(String.self, forKey: .filesDefaultViewModeRaw)
      ?? defaults.filesDefaultViewModeRaw
    filesSplitMinColumnPoints =
      try container.decodeIfPresent(Int.self, forKey: .filesSplitMinColumnPoints)
      ?? defaults.filesSplitMinColumnPoints
    filesAutoPrefetchPatchCap =
      try container.decodeIfPresent(Int.self, forKey: .filesAutoPrefetchPatchCap)
      ?? defaults.filesAutoPrefetchPatchCap
    filesAutoCollapseHunkLineThreshold =
      try container.decodeIfPresent(Int.self, forKey: .filesAutoCollapseHunkLineThreshold)
      ?? defaults.filesAutoCollapseHunkLineThreshold
    filesHideGenerated =
      try container.decodeIfPresent(Bool.self, forKey: .filesHideGenerated)
      ?? defaults.filesHideGenerated
    filesGeneratedPatterns =
      try container.decodeIfPresent([String].self, forKey: .filesGeneratedPatterns)
      ?? defaults.filesGeneratedPatterns
    filesHideWhitespaceOnly =
      try container.decodeIfPresent(Bool.self, forKey: .filesHideWhitespaceOnly)
      ?? defaults.filesHideWhitespaceOnly
    filesMarkViewedSyncWithGitHub =
      try container.decodeIfPresent(Bool.self, forKey: .filesMarkViewedSyncWithGitHub)
      ?? defaults.filesMarkViewedSyncWithGitHub
    filesShowImagePreview =
      try container.decodeIfPresent(Bool.self, forKey: .filesShowImagePreview)
      ?? defaults.filesShowImagePreview
    filesTreeDefaultExpandedDepth =
      try container.decodeIfPresent(Int.self, forKey: .filesTreeDefaultExpandedDepth)
      ?? defaults.filesTreeDefaultExpandedDepth
    filesImagePreviewMaxBytes =
      try container.decodeIfPresent(Int.self, forKey: .filesImagePreviewMaxBytes)
      ?? defaults.filesImagePreviewMaxBytes
    filesLargeDiffStrategyRaw =
      try container.decodeIfPresent(String.self, forKey: .filesLargeDiffStrategyRaw)
      ?? defaults.filesLargeDiffStrategyRaw
    filesLocalCloneThresholdLines =
      try container.decodeIfPresent(Int.self, forKey: .filesLocalCloneThresholdLines)
      ?? defaults.filesLocalCloneThresholdLines
    filesLocalCloneDiskBudgetMB =
      try container.decodeIfPresent(Int.self, forKey: .filesLocalCloneDiskBudgetMB)
      ?? defaults.filesLocalCloneDiskBudgetMB
    filesLocalCloneMaxAgeDays =
      try container.decodeIfPresent(Int.self, forKey: .filesLocalCloneMaxAgeDays)
      ?? defaults.filesLocalCloneMaxAgeDays
    filesAccessibilityPerLineMode =
      try container.decodeIfPresent(Bool.self, forKey: .filesAccessibilityPerLineMode)
      ?? defaults.filesAccessibilityPerLineMode
    showActivityTimeline =
      try container.decodeIfPresent(Bool.self, forKey: .showActivityTimeline)
      ?? defaults.showActivityTimeline
    timelineHiddenKindsRaw =
      try container.decodeIfPresent(String.self, forKey: .timelineHiddenKindsRaw)
      ?? defaults.timelineHiddenKindsRaw
    timelineInitialPageSize =
      try container.decodeIfPresent(Int.self, forKey: .timelineInitialPageSize)
      ?? defaults.timelineInitialPageSize
    timelineLoadOlderBatchSize =
      try container.decodeIfPresent(Int.self, forKey: .timelineLoadOlderBatchSize)
      ?? defaults.timelineLoadOlderBatchSize
    timelineAutoCollapseHeavyReviewThreads =
      try container.decodeIfPresent(Bool.self, forKey: .timelineAutoCollapseHeavyReviewThreads)
      ?? defaults.timelineAutoCollapseHeavyReviewThreads
  }

  var filesDefaultViewMode: FilesViewMode {
    FilesViewMode(rawValue: filesDefaultViewModeRaw) ?? .unified
  }

  var filesLargeDiffStrategy: FilesLargeDiffStrategy {
    FilesLargeDiffStrategy(rawValue: filesLargeDiffStrategyRaw) ?? .autoLocalClone
  }

  /// `Set<DependencyUpdateTimelineKind>` doesn't bridge into
  /// `UserDefaults`, so the raw comma-separated form lives in
  /// `timelineHiddenKindsRaw` and this computed property hops to/from
  /// the typed set the views consume.
  var timelineHiddenKinds: Set<DependencyUpdateTimelineKind> {
    get {
      Set(
        timelineHiddenKindsRaw
          .split(separator: ",")
          .compactMap { DependencyUpdateTimelineKind(rawValue: String($0)) }
      )
    }
    set {
      timelineHiddenKindsRaw =
        newValue
        .map(\.rawValue)
        .sorted()
        .joined(separator: ",")
    }
  }

  var mergeMethod: TaskBoardGitHubMergeMethod {
    TaskBoardGitHubMergeMethod(rawValue: mergeMethodRaw)
  }

  var normalizedOrganizations: [String] {
    Self.normalizedEntries(organizationsText)
  }

  var normalizedRepositories: [String] {
    Self.normalizedEntries(repositoriesText)
  }

  var normalizedExcludeRepositories: [String] {
    Self.normalizedEntries(excludeRepositoriesText)
  }

  var normalizedAuthors: [String] {
    Self.normalizedEntries(authorsText)
  }

  var refreshIntervalDescription: String {
    if refreshIntervalSeconds.isMultiple(of: 60) {
      let minutes = refreshIntervalSeconds / 60
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }
    return "\(refreshIntervalSeconds)s"
  }

  var perRepositoryIntervalDescription: String {
    if perRepositoryIntervalSeconds.isMultiple(of: 60) {
      let minutes = perRepositoryIntervalSeconds / 60
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }
    return "\(perRepositoryIntervalSeconds)s"
  }

  var encodedString: String {
    DashboardDependenciesStorageCodec.encodeToString(self)
  }

  func normalized() -> Self {
    var copy = self
    copy.authorsText = Self.normalizedText(authorsText)
    copy.organizationsText = Self.normalizedText(organizationsText)
    copy.repositoriesText = Self.normalizedText(repositoriesText)
    copy.excludeRepositoriesText = Self.normalizedText(excludeRepositoriesText)
    copy.refreshIntervalSeconds = max(
      refreshIntervalSeconds, Self.minimumPerRepositoryIntervalSeconds)
    copy.cacheMaxAgeSeconds = max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    copy.perRepositoryIntervalSeconds = min(
      max(perRepositoryIntervalSeconds, Self.minimumPerRepositoryIntervalSeconds),
      Self.maximumPerRepositoryIntervalSeconds
    )
    copy.maxConcurrentRepositoryFetches = min(
      max(maxConcurrentRepositoryFetches, Self.minimumConcurrentRepositoryFetches),
      Self.maximumConcurrentRepositoryFetches
    )
    copy.frequentLabelsCount = min(
      max(frequentLabelsCount, Self.minimumFrequentLabelsCount),
      Self.maximumFrequentLabelsCount
    )
    copy.timelineInitialPageSize = Self.normalizedTimelinePageSize(timelineInitialPageSize)
    copy.timelineLoadOlderBatchSize = Self.normalizedTimelinePageSize(
      timelineLoadOlderBatchSize
    )
    return copy
  }

  var normalizedTimelineInitialPageSize: UInt32 {
    UInt32(Self.normalizedTimelinePageSize(timelineInitialPageSize))
  }

  var normalizedTimelineLoadOlderBatchSize: UInt32 {
    UInt32(Self.normalizedTimelinePageSize(timelineLoadOlderBatchSize))
  }

  static func decode(from string: String) -> Self {
    DashboardDependenciesStorageCodec.decode(Self.self, from: string) ?? Self()
  }

  func queryRequest(forceRefresh: Bool) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest(
      authors: normalizedAuthors,
      organizations: normalizedOrganizations,
      repositories: normalizedRepositories,
      excludeRepositories: normalizedExcludeRepositories,
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    )
  }

  func perRepositoryQueryRequest(
    for repository: String,
    forceRefresh: Bool
  ) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest(
      authors: normalizedAuthors,
      organizations: [],
      repositories: [repository],
      excludeRepositories: normalizedExcludeRepositories,
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    )
  }

  private static func normalizedText(_ text: String) -> String {
    normalizedEntries(text).joined(separator: ", ")
  }

  private static func normalizedTimelinePageSize(_ pageSize: Int) -> Int {
    min(max(pageSize, minimumTimelinePageSize), maximumTimelinePageSize)
  }

  private static func normalizedEntries(_ text: String) -> [String] {
    text
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .removingDuplicates()
  }
}
