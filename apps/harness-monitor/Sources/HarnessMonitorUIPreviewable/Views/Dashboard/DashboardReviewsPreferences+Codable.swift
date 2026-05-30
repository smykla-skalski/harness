import Foundation
import HarnessMonitorKit

// Coding lives in this companion file to keep DashboardReviewsPreferences.swift
// under the file-length cap. The custom `encode(to:)` explicitly encodes
// `slaThresholdHours` using `encode` (not `encodeIfPresent`) so that a nil
// value round-trips as JSON null rather than being silently omitted. The
// `init(from:)` mirrors this by checking `contains` before decoding the field.
extension DashboardReviewsPreferences {
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try encodeSourcePreferences(into: &container)
    try encodeDisplayPreferences(into: &container)
    try encodeFilesPreferences(into: &container)
    try encodeTimelinePreferences(into: &container)
    try encodeChecksPreferences(into: &container)
  }

  private func encodeSourcePreferences(
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(authorsText, forKey: .authorsText)
    try container.encode(organizationsText, forKey: .organizationsText)
    try container.encode(repositoriesText, forKey: .repositoriesText)
    try container.encode(excludeRepositoriesText, forKey: .excludeRepositoriesText)
    try container.encode(mergeMethodRaw, forKey: .mergeMethodRaw)
    try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
    try container.encode(cacheMaxAgeSeconds, forKey: .cacheMaxAgeSeconds)
    try container.encode(showLabelDescriptions, forKey: .showLabelDescriptions)
    try container.encode(frequentLabelsCount, forKey: .frequentLabelsCount)
    try container.encode(perRepositoryIntervalSeconds, forKey: .perRepositoryIntervalSeconds)
    try container.encode(maxConcurrentRepositoryFetches, forKey: .maxConcurrentRepositoryFetches)
    try container.encode(expandOrganizations, forKey: .expandOrganizations)
  }

  private func encodeDisplayPreferences(
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(showAvatarsInRows, forKey: .showAvatarsInRows)
    try container.encode(showLabelsInRows, forKey: .showLabelsInRows)
    try container.encode(showLineCountersInRows, forKey: .showLineCountersInRows)
    try container.encode(showPullRequestNumberInRows, forKey: .showPullRequestNumberInRows)
    try container.encode(showPullRequestAgeInRows, forKey: .showPullRequestAgeInRows)
    try container.encode(wrapTitlesInRows, forKey: .wrapTitlesInRows)
    try container.encode(rowTitleMaximumLines, forKey: .rowTitleMaximumLines)
    try container.encode(hideSemanticPrefixesInRowTitles, forKey: .hideSemanticPrefixesInRowTitles)
  }

  private func encodeFilesPreferences(
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(filesEnabled, forKey: .filesEnabled)
    try container.encode(filesDefaultViewModeRaw, forKey: .filesDefaultViewModeRaw)
    try container.encode(filesSoftWrapEnabled, forKey: .filesSoftWrapEnabled)
    try container.encode(filesTabWidth, forKey: .filesTabWidth)
    try container.encode(filesSplitMinColumnPoints, forKey: .filesSplitMinColumnPoints)
    try container.encode(filesAutoPrefetchPatchCap, forKey: .filesAutoPrefetchPatchCap)
    try container.encode(
      filesAutoCollapseHunkLineThreshold, forKey: .filesAutoCollapseHunkLineThreshold
    )
    try container.encode(filesHideGenerated, forKey: .filesHideGenerated)
    try container.encode(filesGeneratedPatterns, forKey: .filesGeneratedPatterns)
    try container.encode(filesHideWhitespaceOnly, forKey: .filesHideWhitespaceOnly)
    try container.encode(filesMarkViewedSyncWithGitHub, forKey: .filesMarkViewedSyncWithGitHub)
    try container.encode(filesShowImagePreview, forKey: .filesShowImagePreview)
    try container.encode(filesTreeDefaultExpandedDepth, forKey: .filesTreeDefaultExpandedDepth)
    try container.encode(filesImagePreviewMaxBytes, forKey: .filesImagePreviewMaxBytes)
    try container.encode(filesLargeDiffStrategyRaw, forKey: .filesLargeDiffStrategyRaw)
    try container.encode(filesLocalCloneThresholdLines, forKey: .filesLocalCloneThresholdLines)
    try container.encode(filesLocalCloneDiskBudgetMB, forKey: .filesLocalCloneDiskBudgetMB)
    try container.encode(filesLocalCloneMaxAgeDays, forKey: .filesLocalCloneMaxAgeDays)
    try container.encode(filesAccessibilityPerLineMode, forKey: .filesAccessibilityPerLineMode)
    try container.encode(filesSortModeRaw, forKey: .filesSortModeRaw)
    try container.encode(filesConversationVisibilityRaw, forKey: .filesConversationVisibilityRaw)
  }

  private func encodeTimelinePreferences(
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(showActivityTimeline, forKey: .showActivityTimeline)
    try container.encode(timelineHiddenKindsRaw, forKey: .timelineHiddenKindsRaw)
    try container.encode(timelineInitialPageSize, forKey: .timelineInitialPageSize)
    try container.encode(timelineLoadOlderBatchSize, forKey: .timelineLoadOlderBatchSize)
    try container.encode(
      timelineAutoCollapseHeavyReviewThreads, forKey: .timelineAutoCollapseHeavyReviewThreads
    )
  }

  private func encodeChecksPreferences(
    into container: inout KeyedEncodingContainer<CodingKeys>
  ) throws {
    try container.encode(checksShowPassingByDefault, forKey: .checksShowPassingByDefault)
    try container.encode(slaThresholdHours, forKey: .slaThresholdHours)
  }

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
    filesSoftWrapEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .filesSoftWrapEnabled)
      ?? defaults.filesSoftWrapEnabled
    filesTabWidth =
      try container.decodeIfPresent(Int.self, forKey: .filesTabWidth)
      ?? defaults.filesTabWidth
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
    slaThresholdHours =
      container.contains(.slaThresholdHours)
      ? try container.decode(Int?.self, forKey: .slaThresholdHours)
      : defaults.slaThresholdHours
  }
}
