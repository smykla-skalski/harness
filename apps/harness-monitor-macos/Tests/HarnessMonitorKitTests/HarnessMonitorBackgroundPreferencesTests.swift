import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Background thumbnail cache")
struct BackgroundThumbnailCacheTests {
  @Test("Thumbnail memory cache evicts older entries beyond the configured limit")
  func thumbnailMemoryCacheEvictsOlderEntriesBeyondConfiguredLimit() async {
    let cache = BackgroundThumbnailCache(
      cacheDirectory: makeTemporaryThumbnailCacheDirectory(),
      maxPixelSize: 64,
      thumbnailMemoryLimit: 2,
      fullImageMemoryLimit: 1
    )
    let selections = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(3))

    _ = await cache.thumbnail(for: selections[0])
    _ = await cache.thumbnail(for: selections[1])
    _ = await cache.thumbnail(for: selections[2])

    let firstKey = cache.cacheKey(for: selections[0])
    let secondKey = cache.cacheKey(for: selections[1])
    let thirdKey = cache.cacheKey(for: selections[2])

    #expect(Set(await cache.thumbnailMemoryCache.keys) == Set([secondKey, thirdKey]))
    #expect(await cache.thumbnailMemoryCache[firstKey] == nil)
  }

  @Test("Full image memory cache stays bounded independently of thumbnails")
  func fullImageMemoryCacheStaysBoundedIndependentlyOfThumbnails() async {
    let cache = BackgroundThumbnailCache(
      cacheDirectory: makeTemporaryThumbnailCacheDirectory(),
      maxPixelSize: 64,
      thumbnailMemoryLimit: 3,
      fullImageMemoryLimit: 1
    )
    let selections = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(3))

    _ = await cache.thumbnail(for: selections[0])
    _ = await cache.thumbnail(for: selections[1])
    _ = await cache.fullImage(for: selections[0])
    _ = await cache.fullImage(for: selections[1])

    let firstKey = cache.cacheKey(for: selections[0])
    let secondKey = cache.cacheKey(for: selections[1])
    let firstFullKey = "full:\(firstKey)"
    let secondFullKey = "full:\(secondKey)"

    #expect(Set(await cache.thumbnailMemoryCache.keys) == Set([firstKey, secondKey]))
    #expect(Set(await cache.fullImageMemoryCache.keys) == Set([secondFullKey]))
    #expect(await cache.fullImageMemoryCache[firstFullKey] == nil)
  }

  @Test(
    "Disk cache writes thumbnails into a noindex directory and removes legacy indexed thumbnails"
  )
  func diskCacheUsesNoIndexDirectoryAndRemovesLegacyIndexedThumbnails() async {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheDirectory = root.appendingPathComponent("cache.noindex/thumbnails", isDirectory: true)
    let legacyDirectory = root.appendingPathComponent("cache/thumbnails", isDirectory: true)
    try? FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    try? Data("legacy".utf8).write(
      to: legacyDirectory.appendingPathComponent("legacy.txt"),
      options: .atomic
    )

    let cache = BackgroundThumbnailCache(
      cacheDirectory: cacheDirectory,
      maxPixelSize: 64,
      thumbnailMemoryLimit: 2,
      fullImageMemoryLimit: 1
    )
    let selection = HarnessMonitorBackgroundSelection.bundledLibrary[0]

    _ = await cache.thumbnail(for: selection)

    let key = cache.cacheKey(for: selection)
    let thumbnailURL = cacheDirectory.appendingPathComponent("\(key).jpg")

    #expect(thumbnailURL.path.contains("/cache.noindex/thumbnails/"))
    #expect(FileManager.default.fileExists(atPath: thumbnailURL.path))
    #expect(FileManager.default.fileExists(atPath: legacyDirectory.path) == false)
  }
}

@Suite("Background gallery prefetch plan")
struct BackgroundGalleryPrefetchPlanTests {
  @Test("Initial plan keeps the selected background warm without prefetching the whole library")
  func initialPlanKeepsSelectedBackgroundWarmWithoutPrefetchingWholeLibrary() {
    let options = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(10))
    let selectedBackground = options[9]
    let recentItems = [options[8]]

    let plan = PreferencesBackgroundGalleryPrefetchPlan.selections(
      options: options,
      recentItems: recentItems,
      selectedBackground: selectedBackground,
      visibleIDs: []
    )

    #expect(
      plan.map { $0.storageValue }
        == Array(options.prefix(10)).map(\.storageValue)
    )
  }

  @Test("Visible tiles expand the plan with overscan and keep entries unique")
  func visibleTilesExpandThePlanWithOverscanAndKeepEntriesUnique() {
    let options = Array(HarnessMonitorBackgroundSelection.bundledLibrary.prefix(10))
    let selectedBackground = options[9]
    let recentItems = [options[0]]

    let plan = PreferencesBackgroundGalleryPrefetchPlan.selections(
      options: options,
      recentItems: recentItems,
      selectedBackground: selectedBackground,
      visibleIDs: [options[3].id, options[4].id]
    )

    #expect(
      plan.map { $0.storageValue }
        == Array(options.prefix(10)).map(\.storageValue)
    )
  }
}

private func makeTemporaryThumbnailCacheDirectory() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
