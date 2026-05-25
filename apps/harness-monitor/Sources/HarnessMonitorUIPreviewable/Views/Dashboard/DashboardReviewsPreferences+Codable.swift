import Foundation
import HarnessMonitorKit

// Decoding lives in this companion file to keep DashboardReviewsPreferences.swift
// under the file-length cap. The struct declares the Codable conformance and lets
// the compiler synthesize `encode(to:)`; only the custom, default-tolerant
// `init(from:)` and its per-section helpers are split out here.
extension DashboardReviewsPreferences {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    try decodeSourcePreferences(from: container, defaults: defaults)
    try decodeDisplayPreferences(from: container, defaults: defaults)
    try decodeFilesPreferences(from: container, defaults: defaults)
    try decodeTimelinePreferences(from: container, defaults: defaults)
    try decodeChecksPreferences(from: container, defaults: defaults)
  }

  private mutating func decodeSourcePreferences(
    from container: KeyedDecodingContainer<CodingKeys>,
    defaults: Self
  ) throws {
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
  }

  private mutating func decodeDisplayPreferences(
    from container: KeyedDecodingContainer<CodingKeys>,
    defaults: Self
  ) throws {
    showAvatarsInRows =
      try container.decodeIfPresent(Bool.self, forKey: .showAvatarsInRows)
      ?? defaults.showAvatarsInRows
    showLabelsInRows =
      try container.decodeIfPresent(Bool.self, forKey: .showLabelsInRows)
      ?? defaults.showLabelsInRows
    showLineCountersInRows =
      try container.decodeIfPresent(Bool.self, forKey: .showLineCountersInRows)
      ?? defaults.showLineCountersInRows
    showPullRequestNumberInRows =
      try container.decodeIfPresent(Bool.self, forKey: .showPullRequestNumberInRows)
      ?? defaults.showPullRequestNumberInRows
    showPullRequestAgeInRows =
      try container.decodeIfPresent(Bool.self, forKey: .showPullRequestAgeInRows)
      ?? defaults.showPullRequestAgeInRows
    wrapTitlesInRows =
      try container.decodeIfPresent(Bool.self, forKey: .wrapTitlesInRows)
      ?? defaults.wrapTitlesInRows
    rowTitleMaximumLines =
      try container.decodeIfPresent(Int.self, forKey: .rowTitleMaximumLines)
      ?? defaults.rowTitleMaximumLines
    hideSemanticPrefixesInRowTitles =
      try container.decodeIfPresent(Bool.self, forKey: .hideSemanticPrefixesInRowTitles)
      ?? defaults.hideSemanticPrefixesInRowTitles
  }

  private mutating func decodeFilesPreferences(
    from container: KeyedDecodingContainer<CodingKeys>,
    defaults: Self
  ) throws {
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
    filesSortModeRaw =
      try container.decodeIfPresent(String.self, forKey: .filesSortModeRaw)
      ?? defaults.filesSortModeRaw
    filesConversationVisibilityRaw =
      try container.decodeIfPresent(String.self, forKey: .filesConversationVisibilityRaw)
      ?? defaults.filesConversationVisibilityRaw
  }

  private mutating func decodeTimelinePreferences(
    from container: KeyedDecodingContainer<CodingKeys>,
    defaults: Self
  ) throws {
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

  private mutating func decodeChecksPreferences(
    from container: KeyedDecodingContainer<CodingKeys>,
    defaults: Self
  ) throws {
    checksShowPassingByDefault =
      try container.decodeIfPresent(Bool.self, forKey: .checksShowPassingByDefault)
      ?? defaults.checksShowPassingByDefault
  }
}
