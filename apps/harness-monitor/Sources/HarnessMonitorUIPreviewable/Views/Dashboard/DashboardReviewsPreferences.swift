import Foundation
import HarnessMonitorKit

struct DashboardReviewsPreferences: Codable, Equatable {
  static let storageKey = "dashboard.reviews.preferences"
  static let minimumPerRepositoryIntervalSeconds: UInt64 = 30
  static let maximumPerRepositoryIntervalSeconds: UInt64 = 3_600
  static let minimumConcurrentRepositoryFetches: Int = 1
  static let maximumConcurrentRepositoryFetches: Int = 8
  static let minimumFrequentLabelsCount: Int = 1
  static let maximumFrequentLabelsCount: Int = 10
  static let defaultFrequentLabelsCount: Int = 5
  static let minimumRowTitleMaximumLines: Int = 2
  static let maximumRowTitleMaximumLines: Int = 6
  static let defaultRowTitleMaximumLines: Int = 2
  static let minimumFilesTabWidth: Int = 1
  static let maximumFilesTabWidth: Int = 16
  static let defaultFilesTabWidth: Int = 8
  static let filesTabWidthRange = minimumFilesTabWidth...maximumFilesTabWidth

  static let minimumTimelinePageSize: Int = 10
  static let maximumTimelinePageSize: Int = 100
  static let defaultTimelinePageSize: Int = 50
  static let defaultTimelineHiddenKindsRaw: String = "mentioned,subscribed,unsubscribed"

  var authorsText = ""
  var organizationsText = ""
  var repositoriesText = ""
  var excludeRepositoriesText = ""
  var mergeMethodRaw = TaskBoardGitHubMergeMethod.squash.rawValue
  var refreshIntervalSeconds: UInt64 = 300
  var cacheMaxAgeSeconds: UInt64 = 600
  var showLabelDescriptions = false
  var showAvatarsInRows = true
  var showLabelsInRows = true
  var showLineCountersInRows = true
  var showPullRequestNumberInRows = true
  var showPullRequestAgeInRows = true
  var wrapTitlesInRows = true
  var rowTitleMaximumLines: Int = defaultRowTitleMaximumLines
  var hideSemanticPrefixesInRowTitles = false
  var frequentLabelsCount: Int = defaultFrequentLabelsCount
  var perRepositoryIntervalSeconds: UInt64 = 300
  var maxConcurrentRepositoryFetches: Int = 2
  var expandOrganizations: Bool = true
  var filesEnabled: Bool = true
  var filesDefaultViewModeRaw: String = FilesViewMode.unified.rawValue
  var filesSoftWrapEnabled: Bool = true
  var filesTabWidth: Int = defaultFilesTabWidth
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
  var checksShowPassingByDefault: Bool = false
  var filesSortModeRaw: String = ReviewFilesSortMode.path.rawValue
  var filesConversationVisibilityRaw: String = ConversationVisibility.all.rawValue

  enum CodingKeys: String, CodingKey {
    case authorsText
    case organizationsText
    case repositoriesText
    case excludeRepositoriesText
    case mergeMethodRaw
    case refreshIntervalSeconds
    case cacheMaxAgeSeconds
    case showLabelDescriptions
    case showAvatarsInRows
    case showLabelsInRows
    case showLineCountersInRows
    case showPullRequestNumberInRows
    case showPullRequestAgeInRows
    case wrapTitlesInRows
    case rowTitleMaximumLines
    case hideSemanticPrefixesInRowTitles
    case frequentLabelsCount
    case perRepositoryIntervalSeconds
    case maxConcurrentRepositoryFetches
    case expandOrganizations
    case filesEnabled
    case filesDefaultViewModeRaw
    case filesSoftWrapEnabled
    case filesTabWidth
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
    case checksShowPassingByDefault
    case filesSortModeRaw
    case filesConversationVisibilityRaw
  }

  static let defaultGeneratedPatterns: [String] = [
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "Cargo.lock",
    "Package.resolved",
    "Gemfile.lock",
    "poetry.lock",
    "go.sum",
    "**/vendor/**",
    "**/node_modules/**",
    "**/dist/**",
    "**/*.pb.go",
    "**/*.pb.cc",
    "**/*.generated.swift",
    "**/*.generated.ts",
    "**/*.generated.js",
  ]
  static let legacyDefaultGeneratedPatterns: [String] = [
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

  var filesDefaultViewMode: FilesViewMode {
    FilesViewMode(rawValue: filesDefaultViewModeRaw) ?? .unified
  }

  var filesLargeDiffStrategy: FilesLargeDiffStrategy {
    FilesLargeDiffStrategy(rawValue: filesLargeDiffStrategyRaw) ?? .autoLocalClone
  }

  var filesSortMode: ReviewFilesSortMode {
    ReviewFilesSortMode(rawValue: filesSortModeRaw) ?? .path
  }

  /// `Set<ReviewTimelineKind>` doesn't bridge into
  /// `UserDefaults`, so the raw comma-separated form lives in
  /// `timelineHiddenKindsRaw` and this computed property hops to/from
  /// the typed set the views consume.
  var timelineHiddenKinds: Set<ReviewTimelineKind> {
    get {
      Set(
        timelineHiddenKindsRaw
          .split(separator: ",")
          .compactMap { ReviewTimelineKind(rawValue: String($0)) }
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
    DashboardReviewsStorageCodec.encodeToString(self)
  }

  func normalized() -> Self {
    var copy = self
    copy.authorsText = Self.normalizedText(authorsText)
    copy.organizationsText = Self.normalizedText(organizationsText)
    copy.repositoriesText = Self.normalizedText(repositoriesText)
    copy.excludeRepositoriesText = Self.normalizedText(excludeRepositoriesText)
    copy.filesGeneratedPatterns = Self.normalizedGeneratedPatterns(filesGeneratedPatterns)
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
    copy.rowTitleMaximumLines = min(
      max(rowTitleMaximumLines, Self.minimumRowTitleMaximumLines),
      Self.maximumRowTitleMaximumLines
    )
    copy.filesTabWidth = min(
      max(filesTabWidth, Self.minimumFilesTabWidth),
      Self.maximumFilesTabWidth
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
    var decoded = DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
    decoded.filesGeneratedPatterns = Self.migratedGeneratedPatterns(decoded.filesGeneratedPatterns)
    // Why: legacy installs persisted the "renovate[bot]" default, which now scopes
    // the dashboard to a single author. The Reviews route fetches all PRs and lets
    // the Category picker surface bot authors, so silently drop the legacy seed.
    if decoded.normalizedAuthors == ["renovate[bot]"] {
      decoded.authorsText = ""
    }
    return decoded
  }

  func queryRequest(forceRefresh: Bool) -> ReviewsQueryRequest {
    ReviewsQueryRequest(
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
  ) -> ReviewsQueryRequest {
    ReviewsQueryRequest(
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

  static func normalizedGeneratedPattern(_ pattern: String) -> String {
    pattern.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func normalizedGeneratedPatterns(_ patterns: [String]) -> [String] {
    patterns
      .map(normalizedGeneratedPattern)
      .filter { !$0.isEmpty }
      .removingDuplicates()
  }

  static func migratedGeneratedPatterns(_ patterns: [String]) -> [String] {
    let normalized = normalizedGeneratedPatterns(patterns)
    if normalized == legacyDefaultGeneratedPatterns {
      return defaultGeneratedPatterns
    }
    return normalized
  }

  mutating func addGeneratedPattern(_ pattern: String) {
    filesGeneratedPatterns = Self.normalizedGeneratedPatterns(filesGeneratedPatterns + [pattern])
  }

  mutating func removeGeneratedPattern(at index: Int) {
    guard filesGeneratedPatterns.indices.contains(index) else { return }
    filesGeneratedPatterns.remove(at: index)
  }

  mutating func restoreDefaultGeneratedPatterns() {
    filesGeneratedPatterns = Self.defaultGeneratedPatterns
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
